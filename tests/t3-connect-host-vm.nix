# tests/t3-connect-host-vm.nix
# Runtime proof for nixosModules.t3-connect-host in two VMs (needs KVM; not part of `checks`, so CI
# without KVM stays green). Run it on a KVM host: `nix build .#t3-connect-host-test -L`.
#
#   host  runs the module, a bridge, two guests (network namespaces joined by veth pairs named vm-*),
#         and a service on 0.0.0.0:8080 that a guest must not reach.
#   world is the "public internet": a web server that returns the address it sees the client at, and
#         a second address inside a blocked range (100.64.7.7) that the host can route to.
#
# The guests are namespaces on the host kernel, so the real bridge, port isolation, FORWARD, INPUT and
# NAT paths all apply. 203.0.113.0/24 (TEST-NET-3) stands in for public addresses: it is not blocked.
{ self }:
{
  name = "t3-connect-host";

  nodes = {
    host =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.t3-connect-host ];
        t3ConnectHost.enable = true;
        # So the spoof test measures the module's rule, not the reverse-path filter's.
        networking.firewall.checkReversePath = false;
        virtualisation.vlans = [ 1 ];
        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "203.0.113.1";
            prefixLength = 24;
          }
        ];
        # A host service that is open to everyone: only the module's INPUT chain keeps a guest out.
        networking.firewall.allowedTCPPorts = [ 8080 ];
        systemd.services.hostsvc = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /tmp";
        };
        environment.systemPackages = [
          pkgs.curl
          pkgs.iproute2
          pkgs.iputils
          pkgs.python3
        ];
      };

    world =
      { pkgs, ... }:
      {
        virtualisation.vlans = [ 1 ];
        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "203.0.113.5";
            prefixLength = 24;
          }
          # Inside a blocked range: the host can route to it, a guest must not.
          {
            address = "100.64.7.7";
            prefixLength = 32;
          }
        ];
        networking.firewall.allowedTCPPorts = [ 80 ];
        services.nginx = {
          enable = true;
          virtualHosts.default = {
            default = true;
            locations."/".return = ''200 "$remote_addr"'';
          };
        };
      };
  };

  testScript = ''
    start_all()
    host.wait_for_unit("multi-user.target")
    host.wait_for_unit("hostsvc.service")
    world.wait_for_unit("nginx.service")
    host.wait_for_unit("network.target")
    # A route to a blocked-range address that `world` owns, so the host itself can reach it.
    host.succeed("ip route replace 100.64.7.7/32 via 203.0.113.5")

    def guest(name, ip):
        host.succeed(f"ip netns add {name}")
        host.succeed(f"ip link add vm-{name} type veth peer name eth0 netns {name}")
        host.succeed(f"ip link set vm-{name} up")
        host.succeed(f"ip -n {name} addr add {ip}/24 dev eth0")
        host.succeed(f"ip -n {name} link set eth0 up")
        host.succeed(f"ip -n {name} link set lo up")
        host.succeed(f"ip -n {name} route add default via 192.168.83.1")

    def in_guest(name, cmd):
        return f"ip netns exec {name} {cmd}"

    def reaches(name, url):
        return in_guest(name, f"curl -s --max-time 3 -o /dev/null {url}")

    guest("g1", "192.168.83.10")
    guest("g2", "192.168.83.11")

    with subtest("networkd puts the matching taps on the bridge, with isolated ports"):
        host.wait_until_succeeds("bridge link show | grep -c 'master t3br0' | grep -qx 2")
        host.succeed("ip -4 addr show t3br0 | grep -q 192.168.83.1/24")
        host.succeed("bridge -d link show dev vm-g1 | grep -q 'isolated on'")
        host.succeed("bridge -d link show dev vm-g2 | grep -q 'isolated on'")

    with subtest("a guest reaches a public address and is masqueraded"):
        out = host.succeed(in_guest("g1", "curl -s --max-time 5 http://203.0.113.5/"))
        assert out.strip() == "203.0.113.1", f"the world should see the host, saw {out!r}"

    with subtest("the path to the blocked range exists, so the drop below is the rule"):
        world.succeed("ip -4 addr show eth1 | grep -q 100.64.7.7")
        host.succeed("ip route get 100.64.7.7 | grep -q 'via 203.0.113.5'")
        host.succeed("curl -s --max-time 5 -o /dev/null http://100.64.7.7/")

    with subtest("a guest cannot reach the blocked ranges"):
        host.fail(reaches("g1", "http://100.64.7.7/"))

    with subtest("a guest cannot reach a host service, on any host address"):
        host.succeed("curl -s --max-time 3 -o /dev/null http://127.0.0.1:8080/")
        host.fail(reaches("g1", "http://192.168.83.1:8080/"))
        host.fail(reaches("g1", "http://203.0.113.1:8080/"))

    with subtest("a published port (DNAT to a public address) is not a way past the host drop"):
        # What docker does for a published container port. Without the mangle rule the DNAT would turn
        # a host address into a forwarded packet to a public address, which t3-fwd allows. The DNAT
        # itself is proved to work by the mutation run that removes the mangle rule: the guest then gets
        # through.
        host.succeed("iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 203.0.113.5:80")
        host.fail(reaches("g1", "http://192.168.83.1:8081/"))
        host.succeed("iptables -t nat -D PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 203.0.113.5:80")

    with subtest("a rule another service puts at the top of FORWARD does not let a guest through"):
        # tailscale and docker insert ACCEPT jumps at position 1 after the firewall started.
        host.succeed("iptables -I FORWARD 1 -j ACCEPT")
        host.fail(reaches("g1", "http://100.64.7.7/"))
        host.succeed("iptables -D FORWARD -j ACCEPT")

    with subtest("two guests cannot reach each other"):
        host.fail(in_guest("g1", "ping -c1 -W2 192.168.83.11"))
        host.fail(in_guest("g2", "ping -c1 -W2 192.168.83.10"))

    with subtest("a spoofed source outside the subnet is dropped by the rule, not by chance"):
        host.succeed("ip -n g1 addr add 198.51.100.9/32 dev eth0")
        host.fail(in_guest("g1", "curl -s --max-time 3 --interface 198.51.100.9 -o /dev/null http://203.0.113.5/"))
        hits = host.succeed(
            "iptables -t mangle -L t3-fwd -v -n -x | awk '$3==\"DROP\" && $8 ~ /^!/ {print $1; exit}'"
        ).strip()
        assert hits.isdigit() and int(hits) > 0, f"the spoof rule dropped no packet (counter {hits!r})"

    with subtest("a guest that changes its own routes still cannot reach a blocked address"):
        host.succeed("ip -n g1 route add 100.64.7.7/32 dev eth0")
        host.fail(reaches("g1", "http://100.64.7.7/"))

    with subtest("a connection the host starts to a guest works, and the reply gets back to the host"):
        # The reply is a new packet from the guest into the host's INPUT chain; only the ESTABLISHED
        # return rule lets it through.
        # A transient unit, not `&`: a background process keeps the test driver's shell open. The unit has a
        # minimal PATH, so the interpreter path is resolved here.
        host.succeed("systemd-run --unit=g1-http " + in_guest("g1", "$(command -v python3) -m http.server 9000 --bind 192.168.83.10 --directory /tmp"))
        for attempt in range(10):
            if host.execute("curl -s --max-time 3 -o /dev/null http://192.168.83.10:9000/")[0] == 0:
                break
            host.execute("sleep 1")
        else:
            print(host.execute("systemctl status g1-http --no-pager; ip -n g1 -br addr; ip -n g1 route; ip route; "
                               "ip netns exec g1 ss -ltn; iptables -t mangle -L PREROUTING -v -n; iptables -L t3-in -v -n")[1])
            raise Exception("the host cannot reach a server in a guest")

    with subtest("a new connection from outside into a guest is dropped"):
        # `world` routes the guest subnet via the host, as a LAN host would.
        world.succeed("ip route replace 192.168.83.0/24 via 203.0.113.1")
        world.fail("curl -s --max-time 3 -o /dev/null http://192.168.83.10:9000/")

    with subtest("a firewall reload keeps one copy of every rule"):
        host.succeed("systemctl reload firewall.service")
        host.succeed("systemctl reload firewall.service")
        # A reload may run the stop commands first, which hides a rule that is added twice. Running the
        # start script again with no stop in between is the case the `-C ... ||` guards protect.
        start = host.succeed(
            "systemctl show firewall.service -p ExecStart --value | grep -o '/nix/store/[^ ;]*firewall-start' | head -1"
        ).strip()
        assert start, "could not find the firewall start script"
        host.succeed(start)
        host.succeed(start)
        for table, chain in [("", "t3-in"), ("-t mangle", "t3-fwd"), ("-t nat", "t3-nat")]:
            n = host.succeed(f"iptables {table} -S | grep -c '^-N {chain}$'").strip()
            assert n == "1", f"{chain} defined {n} times"
        for desc, cmd in [
            ("INPUT jump", "iptables -S INPUT | grep -c -- '-j t3-in'"),
            ("mangle FORWARD jump", "iptables -t mangle -S FORWARD | grep -c -- '-j t3-fwd'"),
            ("mangle FORWARD inbound drop", "iptables -t mangle -S FORWARD | grep -c -- '-o t3br0 .*-j DROP'"),
            ("mangle PREROUTING drop", "iptables -t mangle -S PREROUTING | grep -c -- '-i t3br0 .*-j DROP'"),
            ("filter FORWARD accept", "iptables -S FORWARD | grep -c -- '-i t3br0 -j ACCEPT'"),
            ("nat POSTROUTING jump", "iptables -t nat -S POSTROUTING | grep -c -- '-j t3-nat'"),
            ("ip6 FORWARD drop", "ip6tables -S FORWARD | grep -c -- '-i t3br0 -j DROP'"),
        ]:
            n = host.succeed(cmd).strip()
            assert n == "1", f"{desc}: {n} copies after two reloads"
        host.succeed(in_guest("g1", "curl -s --max-time 5 -o /dev/null http://203.0.113.5/"))
        host.fail(reaches("g1", "http://100.64.7.7/"))

    with subtest("stopping the firewall removes every rule from this module"):
        host.succeed("systemctl stop firewall.service")
        host.fail("iptables -S | grep -q 't3-'")
        host.fail("iptables -t mangle -S | grep -q 't3-'")
        host.fail("iptables -t mangle -S | grep -q t3br0")
        host.fail("iptables -t nat -S | grep -q 't3-'")
        host.fail("ip6tables -S | grep -q 't3'")
  '';
}

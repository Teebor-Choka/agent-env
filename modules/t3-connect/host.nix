# modules/t3-connect/host.nix
# nixosModules.t3-connect-host: a bridge, NAT and a firewall that give guests public egress only. Off
# by default. It lives on the host and a guest never imports it. It knows about a bridge and rules,
# not about microvm.nix, qemu or sandy: the interfaces that join the bridge are matched by name.
# See docs/decisions/t3-connect-layer.md.
#
# What a guest on the bridge may do:
#   - reach public addresses (masqueraded out of the default route) and the resolvers it is given;
#   - not reach the host's own addresses (published container ports included), the LAN, the mesh,
#     link-local or multicast ranges, or any other guest (ports are isolated at L2 and the guest
#     subnet is dropped at L3);
#   - not be reached by a new inbound connection;
#   - not send from a source address outside the subnet.
# Not covered: a guest can still send from another address inside the subnet or answer ARP for it
# (L2 spoofing). Binding an address and a MAC to each port needs bridge-family rules and is not done.
# New guest connections to the host are dropped, DHCP included: guests need static addresses.
# The module needs the iptables firewall (networking.firewall.enable, not nftables).
{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.t3ConnectHost;
  bridge = cfg.bridge.name;
  inherit (cfg.bridge) subnet;
  address = cfg.bridge.address;

  dropBlocked = lib.concatMapStrings (
    net: "iptables -t mangle -A t3-fwd -d ${net} -j DROP\n"
  ) cfg.blockedRanges;

  # Guest egress, in dedicated chains so a firewall reload stays idempotent. The drops live in the
  # mangle table: it runs before nat and filter, and a DROP there is final, so a rule that docker,
  # tailscale or another service later puts at the top of filter FORWARD cannot let a guest through,
  # and a DNAT (a published container port) cannot turn a host address into a forwarded packet.
  #   mangle PREROUTING: new connections from a guest to any host address are dropped before DNAT.
  #   mangle t3-fwd (FORWARD): spoofed sources, the guest subnet itself (no hairpin, so no guest to
  #     guest) and the blocked ranges are dropped; the rest returns to filter.
  #   mangle FORWARD: new connections into a guest are dropped.
  #   filter INPUT t3-in: defence in depth for the host's own addresses; replies to connections the host
  #     starts (ESTABLISHED) pass. Not in raw: raw runs before conntrack and would drop those replies.
  #   filter FORWARD: accepts what mangle let through, and the replies. Position 1, so docker's
  #     default-drop policy does not shadow it.
  #   nat t3-nat (POSTROUTING): masquerade to the public side.
  # IPv6 is not offered: the bridge has no v6 address, and the ip6tables rules are a backstop.
  firewall = ''
    iptables -t mangle -C PREROUTING -i ${bridge} -m conntrack --ctstate NEW -m addrtype --dst-type LOCAL -j DROP 2>/dev/null \
      || iptables -t mangle -I PREROUTING 1 -i ${bridge} -m conntrack --ctstate NEW -m addrtype --dst-type LOCAL -j DROP

    iptables -t mangle -N t3-fwd 2>/dev/null || iptables -t mangle -F t3-fwd
    iptables -t mangle -A t3-fwd ! -s ${subnet} -j DROP
    iptables -t mangle -A t3-fwd -d ${subnet} -j DROP
    ${dropBlocked}iptables -t mangle -A t3-fwd -j RETURN
    iptables -t mangle -C FORWARD -i ${bridge} -j t3-fwd 2>/dev/null \
      || iptables -t mangle -I FORWARD 1 -i ${bridge} -j t3-fwd
    iptables -t mangle -C FORWARD -o ${bridge} -m conntrack --ctstate NEW -j DROP 2>/dev/null \
      || iptables -t mangle -I FORWARD 1 -o ${bridge} -m conntrack --ctstate NEW -j DROP

    iptables -N t3-in 2>/dev/null || iptables -F t3-in
    iptables -A t3-in -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -A t3-in -j DROP
    iptables -C INPUT -i ${bridge} -j t3-in 2>/dev/null \
      || iptables -I INPUT 1 -i ${bridge} -j t3-in

    iptables -C FORWARD -i ${bridge} -j ACCEPT 2>/dev/null \
      || iptables -I FORWARD 1 -i ${bridge} -j ACCEPT
    iptables -C FORWARD -o ${bridge} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
      || iptables -I FORWARD 1 -o ${bridge} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    iptables -t nat -N t3-nat 2>/dev/null || iptables -t nat -F t3-nat
    iptables -t nat -A t3-nat ! -d ${subnet} -j MASQUERADE
    iptables -t nat -C POSTROUTING -s ${subnet} -j t3-nat 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s ${subnet} -j t3-nat
    ${lib.optionalString config.networking.enableIPv6 ''
      ip6tables -N t3-in6 2>/dev/null || ip6tables -F t3-in6
      ip6tables -A t3-in6 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
      ip6tables -A t3-in6 -j DROP
      ip6tables -C INPUT -i ${bridge} -j t3-in6 2>/dev/null \
        || ip6tables -I INPUT 1 -i ${bridge} -j t3-in6
      ip6tables -C FORWARD -i ${bridge} -j DROP 2>/dev/null \
        || ip6tables -I FORWARD 1 -i ${bridge} -j DROP
    ''}
  '';

  firewallStop = ''
    iptables -t mangle -D PREROUTING -i ${bridge} -m conntrack --ctstate NEW -m addrtype --dst-type LOCAL -j DROP 2>/dev/null || true
    iptables -t mangle -D FORWARD -i ${bridge} -j t3-fwd 2>/dev/null || true
    iptables -t mangle -D FORWARD -o ${bridge} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
    iptables -t mangle -F t3-fwd 2>/dev/null || true
    iptables -t mangle -X t3-fwd 2>/dev/null || true
    iptables -D INPUT -i ${bridge} -j t3-in 2>/dev/null || true
    iptables -F t3-in 2>/dev/null || true
    iptables -X t3-in 2>/dev/null || true
    iptables -D FORWARD -i ${bridge} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o ${bridge} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s ${subnet} -j t3-nat 2>/dev/null || true
    iptables -t nat -F t3-nat 2>/dev/null || true
    iptables -t nat -X t3-nat 2>/dev/null || true
    ${lib.optionalString config.networking.enableIPv6 ''
      ip6tables -D INPUT -i ${bridge} -j t3-in6 2>/dev/null || true
      ip6tables -F t3-in6 2>/dev/null || true
      ip6tables -X t3-in6 2>/dev/null || true
      ip6tables -D FORWARD -i ${bridge} -j DROP 2>/dev/null || true
    ''}
  '';
in
{
  options.t3ConnectHost = {
    enable = lib.mkEnableOption "the t3-connect host network (a bridge, NAT and a firewall for guests)";

    bridge = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "t3br0";
        description = ''
          Bridge name. It must not start with `br-`: hosts that run docker commonly trust `br-+` for
          input, which would open the host to every guest. At most 15 characters.
        '';
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = "192.168.83.1";
        description = "The host's address on the bridge. It is the guests' gateway.";
      };
      subnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.83.0/24";
        description = "The guests' subnet. Change it together with `address`, and keep it a /24.";
      };
    };

    tapMatch = lib.mkOption {
      type = lib.types.str;
      default = "vm-*";
      description = ''
        Interface name pattern whose members join the bridge with isolated ports. Anything that
        creates guest taps (microvm.nix, a script, a sandbox runner) only has to name them to match.
        Pick a pattern that no other bridge on the host also uses.
      '';
    };

    blockedRanges = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "0.0.0.0/8"
        "10.0.0.0/8"
        "100.64.0.0/10"
        "127.0.0.0/8"
        "169.254.0.0/16"
        "172.16.0.0/12"
        "192.0.0.0/24"
        "192.168.0.0/16"
        "198.18.0.0/15"
        "224.0.0.0/3"
      ];
      description = ''
        Destinations a guest may not reach: private, mesh (100.64.0.0/10), link-local, loopback and
        multicast ranges. Everything else is forwarded and masqueraded.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "t3ConnectHost needs the iptables firewall: set networking.firewall.enable = true and leave networking.nftables.enable off. Without it the bridge forwards with no rules.";
      }
      {
        assertion = !(lib.hasPrefix "br-" bridge);
        message = "t3ConnectHost.bridge.name = \"${bridge}\" starts with br-, which NixOS hosts running docker trust for input.";
      }
      {
        assertion = builtins.stringLength bridge <= 15;
        message = "t3ConnectHost.bridge.name = \"${bridge}\" is longer than the 15 characters an interface name allows.";
      }
    ];

    # networkd manages only the bridge and the taps; NetworkManager keeps everything else.
    systemd.network.enable = true;
    networking.networkmanager.unmanaged = lib.mkIf config.networking.networkmanager.enable [
      "interface-name:${bridge}"
      "interface-name:${cfg.tapMatch}"
    ];
    # dhcpcd (useDHCP defaults on in a generated config) would also run on the bridge and the taps,
    # and DHCP uses packet sockets that netfilter never sees: a guest could push resolvers and routes.
    networking.dhcpcd.denyInterfaces = [
      bridge
      cfg.tapMatch
    ];
    systemd.network.netdevs."20-${bridge}".netdevConfig = {
      Kind = "bridge";
      Name = bridge;
    };
    systemd.network.networks."20-${bridge}" = {
      matchConfig.Name = bridge;
      linkConfig.RequiredForOnline = "no";
      address = [ "${address}/${lib.last (lib.splitString "/" subnet)}" ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
        # Forwarding is checked on the ingress interface, so it is on for the bridge here and for the
        # uplink through the global sysctl below. What a guest may reach is decided by t3-fwd.
        IPv4Forwarding = true;
        IPv6Forwarding = false;
      };
    };
    systemd.network.networks."21-t3-taps" = {
      matchConfig.Name = cfg.tapMatch;
      linkConfig.RequiredForOnline = "no";
      networkConfig.Bridge = bridge;
      # Isolated ports reach the bridge's own address but not each other.
      bridgeConfig.Isolated = true;
    };

    # NAT needs routing on the uplink too, not only on the bridge: a reply from the internet enters
    # on the uplink and is forwarded to the bridge after conntrack undoes the NAT, and the kernel
    # checks forwarding on the ingress interface. A host with docker gets this by accident; a plain
    # host does not, and guests would silently have no egress. What a guest may reach is decided by
    # the mangle t3-fwd chain, not by this sysctl.
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;

    networking.firewall.extraCommands = firewall;
    networking.firewall.extraStopCommands = firewallStop;
  };
}

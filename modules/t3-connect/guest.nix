# modules/t3-connect/guest.nix
# nixosModules.t3-connect: what runs inside a sandbox so a T3 Code client can reach it. Off by
# default; with `t3Connect.enable = false` it adds nothing. See docs/decisions/t3-connect-layer.md.
#
# It names a secrets directory and a marker, never a hypervisor or a share: whoever builds the
# sandbox fills the directory before boot and writes the marker last.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.t3Connect;
  inherit (cfg) secretsDir;
  home = config.users.users.${cfg.user}.home;
  marker = "${secretsDir}/${cfg.ready.marker}";
  has = harness: builtins.elem harness cfg.harnesses;
  boolStr = b: if b then "true" else "false";

  # Provider instances to seed. t3 turns Claude and Codex on by itself but leaves opencode off until
  # an instance exists in the settings, so a harness that is in the image gets one. `providers`
  # wins over that default.
  seeded = (lib.optionalAttrs (has "opencode") { opencode = true; }) // cfg.providers;

  # `//=` adds an entry only when absent, so a change made in the app persists across restarts.
  seedFilter =
    let
      parts =
        lib.optional cfg.linkedEnvironments ".linkedEnvironmentsEnabled = true"
        ++ lib.mapAttrsToList (
          name: on: ''.providerInstances.${name} //= {"driver": "${name}", "enabled": ${boolStr on}}''
        ) seeded;
    in
    if parts == [ ] then "." else lib.concatStringsSep " | " parts;

  # Linked environments is a beta, off by default, and a link needs it on at both ends.
  seedScript = ''
    f=${cfg.baseDir}/userdata/settings.json
    mkdir -p "$(dirname "$f")"
    [ -s "$f" ] || echo '{}' > "$f"
    ${pkgs.jq}/bin/jq '${seedFilter}' "$f" > "$f.new" && mv -f "$f.new" "$f"
  '';

  # Reads each credential at start and exports it for t3 and its children. The agent can read its own
  # token anyway; the boundary is the sandbox.
  # Plain http on purpose: Headscale does not implement the https feature Tailscale Serve needs (it
  # answers 501), and the mesh already encrypts the path.
  runScript = ''
    ${
      lib.concatStrings (
        lib.mapAttrsToList (var: file: ''
          export ${var}="$(cat "$CREDENTIALS_DIRECTORY/${file}")"
        '') cfg.credentials
      )
    }exec ${cfg.package}/bin/t3 serve --host ${cfg.bind} --port ${toString cfg.port} \
      --base-dir ${cfg.baseDir}
  '';

  # A path unit never fires here: virtiofs does not deliver inotify events for files the host writes
  # after boot. The stamp is the marker's mtime, so a re-inject (new secrets, new join key) restarts
  # the units and a quiet poll does nothing.
  readyScript = ''
    [ -e ${marker} ] || exit 0
    stamp=$(stat -c %Y ${marker})
    [ "$(cat /run/t3-ready-stamp 2>/dev/null)" = "$stamp" ] && exit 0
    echo "$stamp" > /run/t3-ready-stamp
    systemctl restart --no-block t3-serve.service${lib.optionalString cfg.mesh.enable " tailscaled-autoconnect.service"}
    ${lib.optionalString cfg.mesh.enable "systemctl restart --no-block t3-hostname.service"}
  '';

  # No persisted node identity: every boot is a new node. The injector picks a unique name and writes
  # it to `secretsDir`, so the orchestrator knows the name before the guest joins.
  hostnameScript = ''
    [ -s ${secretsDir}/${cfg.mesh.hostnameFile} ] || exit 0
    tailscale set --hostname="$(cat ${secretsDir}/${cfg.mesh.hostnameFile})"
  '';

  # `t3 pair` prints a block of text; a delegator wants only the code. It must run as the t3 user: the
  # code is minted in that user's data directory. The code is one-time and short-lived (default 5 m).
  pairScript = ''
    tok=$(${cfg.package}/bin/t3 pair --base-dir ${cfg.baseDir} --ttl "''${1:-5m}" --label "''${2:-delegator}" 2>/dev/null \
      | sed -n 's/^Token: //p')
    [ -n "$tok" ] || { echo "t3-pair: no code (is t3-serve running, and are you the ${cfg.user} user?)" >&2; exit 1; }
    printf '%s\n' "$tok"
  '';
in
{
  options.t3Connect = {
    enable = lib.mkEnableOption "the t3-connect layer (t3 serve, mesh join, link support)";

    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "The existing ordinary account `t3 serve` runs as.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.t3-server;
      defaultText = lib.literalExpression "pkgs.t3-server";
      description = "The headless t3 build (from `overlays.default`).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
      description = "TCP port of `t3 serve`.";
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "::";
      description = ''
        Address `t3 serve` binds. `::` serves IPv4 and IPv6: a peer link refuses plain http unless the
        host is loopback or inside the tailnet IPv6 range (fd7a:115c:a1e0::/48), so a delegator
        reaches the guest by that address.
      '';
    };

    baseDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}/.t3";
      defaultText = lib.literalExpression ''"/home/''${config.t3Connect.user}/.t3"'';
      description = "The t3 data directory (`--base-dir`).";
    };

    secretsDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets";
      description = "Directory a host fills before boot. The marker is written last.";
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        CLAUDE_CODE_OAUTH_TOKEN = "claude-oauth-token";
      };
      description = "Environment variable to file name in `secretsDir`, exported to t3 and its children.";
    };

    harnesses = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "claude"
          "opencode"
          "codex"
        ]
      );
      default = [ "claude" ];
      description = "Harness CLIs present in the image. Each is put on the server's PATH.";
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf lib.types.bool;
      default = { };
      example = {
        codex = false;
      };
      description = ''
        t3 driver name to enabled flag, seeded into the settings only when absent. A harness that
        t3 does not enable by default (opencode) is seeded enabled unless this says otherwise.
      '';
    };

    linkedEnvironments = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Seed `linkedEnvironmentsEnabled` (a beta, off by default, needed at both ends of a link).";
    };

    mesh = {
      enable = lib.mkEnableOption "joining the mesh with a pre-auth key from `secretsDir`";
      loginServer = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "https://mesh.example.net";
        description = "Coordination server URL (Headscale or Tailscale).";
      };
      authKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "tailscale-authkey";
        description = "File name of the single-use pre-auth key in `secretsDir`.";
      };
      hostnameFile = lib.mkOption {
        type = lib.types.str;
        default = "hostname";
        description = "File name in `secretsDir` that names the mesh node; read after each join.";
      };
    };

    ready = {
      marker = lib.mkOption {
        type = lib.types.str;
        default = ".ready";
        description = "File name in `secretsDir` written last; a new mtime starts the join and the server.";
      };
      pollInterval = lib.mkOption {
        type = lib.types.str;
        default = "5s";
        description = "How often the marker is checked. A path unit never fires on virtiofs, so this polls.";
      };
    };

    generated = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "The texts of the generated scripts, exposed for the eval checks.";
    };
  };

  config = lib.mkMerge [
    # Defined once and unconditionally (a read-only option takes exactly one definition). The texts
    # are lazy: a disabled system never forces them.
    {
      t3Connect.generated = {
        run = runScript;
        seed = seedScript;
        ready = readyScript;
        hostname = hostnameScript;
        pair = pairScript;
      };
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          assertions = [
            {
              assertion = config.users.users ? ${cfg.user};
              message = "t3Connect.user = \"${cfg.user}\" is not a declared user.";
            }
            {
              assertion = builtins.match "[0-9a-fA-F:]+|[0-9]{1,3}(\\.[0-9]{1,3}){3}" cfg.bind != null;
              message = "t3Connect.bind = \"${cfg.bind}\" is not an IPv4 or IPv6 address (use \"::\" for all).";
            }
            {
              assertion = !cfg.mesh.enable || lib.hasPrefix "https://" cfg.mesh.loginServer;
              message = "t3Connect.mesh.loginServer must be an https URL when t3Connect.mesh.enable is set.";
            }
          ];

          nixpkgs.overlays = [ self.overlays.default ];
          # claude-code is the only unfree package the server wrapper pulls in.
          nixpkgs.config.allowUnfreePredicate = lib.mkDefault (pkg: lib.getName pkg == "claude-code");

          # For a delegator that links this guest: `ssh <guest> t3-pair` prints a one-time code.
          environment.systemPackages = [ (pkgs.writeShellScriptBin "t3-pair" pairScript) ];

          # No wantedBy on purpose: the guest does nothing until the host marks the secrets ready, and
          # the poller below starts the server.
          systemd.services.t3-serve = {
            description = "T3 Code headless server";
            # `after` the join, not `requires`: a failed join must not block t3 itself, and the node
            # name must be applied before the server reports its address.
            after = [
              "network.target"
            ]
            ++ lib.optionals cfg.mesh.enable [
              "tailscaled.service"
              "tailscaled-autoconnect.service"
              "t3-hostname.service"
            ];
            # opencode is not in the t3 wrapper's PATH (only claude, codex, git, gh), so add it here.
            path =
              lib.optional cfg.mesh.enable config.services.tailscale.package
              ++ lib.optional (has "opencode") pkgs.opencode;
            environment = {
              HOME = home;
              # Nix owns the versions; keep updates and telemetry off in the sandbox.
              CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
              DISABLE_TELEMETRY = "1";
              DISABLE_UPDATES = "1";
            };
            serviceConfig = {
              User = cfg.user;
              WorkingDirectory = home;
              # `LoadCredential` runs as root, so the files stay root-only until the script exports them.
              LoadCredential = lib.mapAttrsToList (_: file: "${file}:${secretsDir}/${file}") cfg.credentials;
              ExecStartPre = pkgs.writeShellScript "t3-settings" seedScript;
              ExecStart = pkgs.writeShellScript "t3-run" runScript;
              Restart = "always";
              RestartSec = 5;
              NoNewPrivileges = true;
            };
          };

          systemd.services.t3-ready = {
            description = "Start t3 and the mesh join when the secrets are ready";
            serviceConfig.Type = "oneshot";
            script = readyScript;
          };
          systemd.timers.t3-ready = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = cfg.ready.pollInterval;
              OnUnitInactiveSec = cfg.ready.pollInterval;
            };
          };
        }

        (lib.mkIf cfg.mesh.enable {
          services.tailscale = {
            enable = true;
            authKeyFile = "${secretsDir}/${cfg.mesh.authKeyFile}";
            extraUpFlags = [
              "--login-server=${cfg.mesh.loginServer}"
              # No --advertise-tags: the tag rides on the pre-auth key. A tagged key has no user owner,
              # so the server refuses a client-requested tag as "not permitted".
              # `up` refuses to run when saved prefs hold a non-default value it does not mention, so the
              # operator is named here too.
              "--operator=${cfg.user}"
              # A re-inject in the same boot finds prefs saved by `tailscale set --hostname`
              # (t3-hostname), and `up` refuses without this. Its error hint also prints the auth key
              # into the journal: treat a key as burned after that error.
              "--reset"
            ];
            extraSetFlags = [ "--operator=${cfg.user}" ];
          };
          # Only the key file gates the join; wait for the host's marker.
          systemd.services.tailscaled-autoconnect.unitConfig.ConditionPathExists = marker;
          systemd.services.t3-hostname = {
            description = "Name the mesh node from the injected hostname";
            after = [ "tailscaled-autoconnect.service" ];
            path = [ config.services.tailscale.package ];
            serviceConfig.Type = "oneshot";
            script = hostnameScript;
          };
          # t3 is reachable from the mesh only; the coordination server's policy further limits who.
          networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
        })
      ]
    ))
  ];
}

{
  description = "Nix packaging for agentic-tooling PyPI packages with no nixpkgs equivalent (headroom-ai)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Source of the packages the agentic overlay grafts in (codebase-memory-mcp, omp). A consumer
    # on a stable nixpkgs follows its own unstable tree here.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # headroom-ai and its onnxruntime chain ship no macOS wheel (confirmed:
      # PyPI only publishes manylinux_2_28_{x86_64,aarch64} for 0.41.0) -- this flake
      # only ever needs to run on the Linux dev microVM guests that actually install
      # these tools, which are aarch64-linux on this Apple Silicon host (the Mac's
      # vfkit/Virtualization.framework guests) with x86_64-linux kept too since it is a
      # real, independently reachable builder (ws01).
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      forEachSystem = lib.genAttrs systems;

      mkAgenticTools =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

          overlay = workspace.mkPyprojectOverlay {
            sourcePreference = "wheel";
          };

          pythonSet =
            (pkgs.callPackage pyproject-nix.build.packages {
              python = pkgs.python313;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  pyproject-build-systems.overlays.wheel
                  overlay
                ]
              );
        in
        # One environment carrying headroom and its entry-point scripts on PATH. The name stays
        # `agentic-tools` so the consuming flake's overlay needs no change.
        pythonSet.mkVirtualEnv "agentic-tools-env" workspace.deps.default;

      agenticToolsBySystem = forEachSystem mkAgenticTools;

      # Packages every agentic guest or host needs, keyed to prev's platform so one overlay serves the
      # darwin host and the linux guests. agentic-tools is lazily bound: it exists for linux only, and
      # the darwin host runs headroom through uvx instead.
      overlay =
        _final: prev:
        let
          system = prev.stdenv.hostPlatform.system;
          unstable = nixpkgs-unstable.legacyPackages.${system};
        in
        {
          # C11 MCP server that indexes a codebase into a knowledge graph.
          inherit (unstable) codebase-memory-mcp omp;
          agentic-tools = self.packages.${system}.agentic-tools;
          # Headless `t3 serve` for the t3-connect layer, with Claude on its PATH. The desktop wrapper is
          # removed so electron leaves the runtime closure; on darwin the .app bundle symlinks to it, so
          # the removal is Linux only. Its own unstable instance allows the unfree claude-code.
          t3-server =
            let
              unfree = import nixpkgs-unstable {
                inherit system;
                config.allowUnfree = true;
              };
            in
            unfree.t3code.override {
              t3code-unwrapped = unfree.t3code.unwrapped.overrideAttrs (old: {
                postFixup =
                  (old.postFixup or "")
                  + lib.optionalString prev.stdenv.hostPlatform.isLinux ''
                    rm -f "$out"/bin/t3code-desktop
                  '';
              });
              enableClaude = true;
            };
        };
    in
    {
      overlays.default = overlay;

      # The agentic environment (modules/agentic.nix), once per platform: the option trees for
      # services (systemd vs launchd) and shell init differ, so the platform is fixed per export.
      nixosModules.agentic = import ./modules/agentic.nix {
        inherit self;
        isLinuxHost = true;
      };
      # The thinnest agent sandbox (modules/sandbox.nix): the chosen harnesses preconfigured in system
      # locations, no home-manager and no user. For builders that supply only a bare guest, such as
      # `sandy run --flake <this flake> --kind nixos-module --attr sandbox`.
      nixosModules.sandbox = import ./modules/sandbox.nix { inherit self; };
      # The t3-connect layer (docs/decisions/t3-connect-layer.md), guest side: off unless
      # `t3Connect.enable`.
      nixosModules.t3-connect = import ./modules/t3-connect/guest.nix { inherit self; };
      # The whole t3 guest in one import: `sandbox` plus `t3-connect`, wired together. Set
      # `t3Connect.mesh.loginServer`; import it instead of the two it combines.
      nixosModules.t3-sandbox = import ./modules/t3-connect/sandbox.nix { inherit self; };
      # The image-side pieces of a T3 guest only (user, t3, readiness probe, github credential helper):
      # no service, secret or mesh. For builders that start `t3 serve` themselves, such as sandy.
      nixosModules.t3-guest = import ./modules/t3-connect/t3-guest.nix { inherit self; };
      # The same layer's host side, optional and separate: a bridge, NAT and a firewall that give
      # guests public egress only. A guest never imports it.
      nixosModules.t3-connect-host = import ./modules/t3-connect/host.nix { inherit self; };
      darwinModules.agentic = import ./modules/agentic.nix {
        inherit self;
        isLinuxHost = false;
      };
      # home.agentPlugins, home.skillLink, home.swePlugin. Also registered by the modules above.
      homeModules.agentic = ./modules/home;
      # t3-link-vm and t3-unlink-vm, for the machine that runs the T3 app (the delegator). Needs the consumer to apply
      # overlays.default (t3-server) or pass `t3Connect.delegator.package`.
      homeModules.t3-connect-delegator = import ./modules/t3-connect/delegator.nix { inherit self; };

      packages =
        forEachSystem (
          system:
          let
            t3Pkgs = import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            };
          in
          {
            default = agenticToolsBySystem.${system};
            agentic-tools = agenticToolsBySystem.${system};
            t3-link-vm = import ./modules/t3-connect/link-vm.nix { pkgs = t3Pkgs; };
            t3-unlink-vm = import ./modules/t3-connect/unlink-vm.nix { pkgs = t3Pkgs; };
            t3-run-vm = import ./modules/t3-connect/run-vm.nix { pkgs = t3Pkgs; };
          }
          # Runtime proof of the host network module in two VMs. Needs KVM, so it is a package to run by
          # hand on a KVM host (`nix build .#t3-connect-host-test -L`), not a check.
          // lib.optionalAttrs (system == "x86_64-linux") {
            t3-connect-host-test = nixpkgs.legacyPackages.${system}.testers.runNixOSTest (
              import ./tests/t3-connect-host-vm.nix { inherit self; }
            );
          }
        )
        # The delegator's tools run on the machine with the T3 app, which is the Mac. Scripts only: the
        # t3 CLI must match the app, so pass `T3_BIN` or `t3Connect.delegator.package`.
        // {
          aarch64-darwin =
            let
              t3Pkgs = import nixpkgs {
                system = "aarch64-darwin";
                overlays = [ self.overlays.default ];
              };
            in
            {
              t3-link-vm = import ./modules/t3-connect/link-vm.nix { pkgs = t3Pkgs; };
              t3-unlink-vm = import ./modules/t3-connect/unlink-vm.nix { pkgs = t3Pkgs; };
              t3-run-vm = import ./modules/t3-connect/run-vm.nix { pkgs = t3Pkgs; };
            };
        };

      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Shared by the t3-* checks: the stub that lets a module set evaluate as a whole system, an
          # option read that returns a default instead of aborting, and "this configuration is refused".
          stubSystem = {
            nixpkgs.hostPlatform = system;
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "/dev/null";
              fsType = "ext4";
            };
            system.stateVersion = "24.05";
          };
          get =
            sys: path: default:
            lib.attrByPath path default sys.config;
          evalFails = sys: !(builtins.tryEval sys.config.system.build.toplevel.drvPath).success;
        in
        {
          build = agenticToolsBySystem.${system};

          # nixosModules.sandbox must evaluate into a complete NixOS system for every tool choice, with
          # the user and the home files each tool needs. Forcing each system's drvPath at eval time fails the
          # check on any option, assertion or overlay error; the live boot (sandy) is run by hand,
          # see README.
          sandbox-eval =
            let
              evalWith =
                tools:
                nixpkgs.lib.nixosSystem {
                  modules = [
                    self.nixosModules.sandbox
                    {
                      sandbox.tools = tools;
                      nixpkgs.hostPlatform = system;
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "/dev/null";
                        fsType = "ext4";
                      };
                      system.stateVersion = "24.05";
                    }
                  ];
                };
              claudeOnly = evalWith [ "claude" ];
              all = evalWith [
                "claude"
                "opencode"
                "codex"
              ];
              rulesOf = sys: lib.concatStringsSep "\n" sys.config.systemd.tmpfiles.rules;
              has = sys: path: lib.hasInfix "/home/user/${path} " (rulesOf sys);
              ok =
                builtins.all (path: has all path) [
                  ".claude.json"
                  ".claude/settings.json"
                  ".config/opencode/opencode.json"
                  ".codex/config.toml"
                ]
                # an ordinary account with a home, owned by it
                && all.config.users.users.user.isNormalUser
                && all.config.users.users.user.home == "/home/user"
                # a tool that is not selected leaves no config behind
                && !(has claudeOnly ".codex/config.toml")
                && !(has claudeOnly ".config/opencode/opencode.json");
              systems' = [
                claudeOnly
                (evalWith [ "opencode" ])
                (evalWith [ "codex" ])
                all
              ];
            in
            assert ok;
            pkgs.writeText "sandbox-eval" (
              builtins.unsafeDiscardStringContext (
                lib.concatMapStringsSep "\n" (sys: sys.config.system.build.toplevel.drvPath) systems'
              )
            );

          # nixosModules.t3-guest: the image-side pieces of a T3 guest, with no service, secret or mesh. The
          # generated script texts are exposed as `t3Guest.generated`, so no build is needed.
          t3-guest-eval =
            let
              evalWith =
                extra:
                nixpkgs.lib.nixosSystem {
                  modules = [
                    self.nixosModules.t3-guest
                    stubSystem
                    {
                      nixpkgs.overlays = [ self.overlays.default ];
                      nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
                    }
                    extra
                  ];
                };
              off = evalWith { t3Guest.enable = false; };
              on = evalWith { t3Guest.enable = true; };
              custom = evalWith {
                t3Guest = {
                  enable = true;
                  user = "agent";
                  home = "/srv/agent";
                  git.credentialHelper = false;
                };
              };
              badHome = evalWith {
                t3Guest = {
                  enable = true;
                  home = "relative/path";
                };
              };
              badUser = evalWith {
                t3Guest = {
                  enable = true;
                  user = "Bad User";
                };
              };
              has = needle: hay: lib.hasInfix needle hay;
              gen = sys: name: sys.config.t3Guest.generated.${name};
              # programs.git.config merges into a list of attribute sets.
              gitCfg = sys: lib.foldl' lib.recursiveUpdate { } (lib.toList sys.config.programs.git.config);
              pkgNames = sys: map lib.getName sys.config.environment.systemPackages;
              cases = {
                "disabled adds no user and no probe" =
                  !(off.config.users.users ? t3) && !(builtins.elem "t3-ready-probe" (pkgNames off));
                "enabled adds a system user with its own home" =
                  on.config.users.users.t3.isSystemUser
                  && on.config.users.users.t3.home == "/var/lib/t3"
                  && on.config.users.users.t3.group == "t3";
                "enabled puts t3 and the probe in the image" =
                  builtins.elem "t3-ready-probe" (pkgNames on) && builtins.elem "t3code" (pkgNames on);
                "the image defines no service and no secret" =
                  !(on.config.systemd.services ? t3-serve) && !(on.config.systemd.services ? t3-ready);
                "the probe accepts any status below 500 and checks the port range" =
                  has "65535" (gen on "probe") && has "-lt 500" (gen on "probe");
                "the credential helper tries GH_TOKEN, then GITHUB_TOKEN, then the credential file" =
                  has "GH_TOKEN" (gen on "credential")
                  && has "GITHUB_TOKEN" (gen on "credential")
                  && has "gh-token" (gen on "credential");
                "the helper is registered for github.com over https" =
                  lib.hasPrefix "!"
                    (gitCfg on).credential."https://github.com".helper;
                "user and home follow the options" = custom.config.users.users.agent.home == "/srv/agent";
                "the helper can be turned off" = !((gitCfg custom) ? credential);
                "a relative home is refused" = evalFails badHome;
                "a user name that is not a login name is refused" = evalFails badUser;
              };
              failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
            in
            assert lib.assertMsg (failed == [ ]) "t3-guest-eval failed: ${lib.concatStringsSep "; " failed}";
            pkgs.writeText "t3-guest-eval" (
              builtins.unsafeDiscardStringContext (
                lib.concatMapStringsSep "\n" (sys: sys.config.system.build.toplevel.drvPath) [
                  off
                  on
                  custom
                ]
              )
            );

          # nixosModules.t3-connect: acceptance checks on the evaluated NixOS config, the module's
          # public contract (docs/decisions/t3-connect-layer.md). Disabled adds nothing; enabled wires
          # the units, the credentials, the settings seed, the mesh join and the firewall as specified.
          # The generated script texts are exposed as `t3Connect.generated`, so no build is needed.
          t3-connect-eval =
            let
              evalWith =
                extra:
                nixpkgs.lib.nixosSystem {
                  modules = [
                    self.nixosModules.t3-connect
                    stubSystem
                    {
                      nixpkgs.overlays = [ self.overlays.default ];
                      nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
                      users.users.user.isNormalUser = true;
                    }
                    extra
                  ];
                };
              off = evalWith { t3Connect.enable = false; };
              on = evalWith {
                t3Connect = {
                  enable = true;
                  credentials.CLAUDE_CODE_OAUTH_TOKEN = "claude-oauth-token";
                  harnesses = [
                    "claude"
                    "opencode"
                  ];
                  providers.codex = false;
                  mesh = {
                    enable = true;
                    loginServer = "https://mesh.example.net";
                  };
                };
              };
              userOff = evalWith {
                t3Connect = {
                  enable = true;
                  harnesses = [
                    "claude"
                    "opencode"
                  ];
                  providers.opencode = false;
                };
              };
              noMesh = evalWith { t3Connect.enable = true; };
              noFirewall = evalWith {
                networking.firewall.enable = false;
                t3Connect.enable = true;
              };
              badCred = evalWith {
                t3Connect = {
                  enable = true;
                  credentials."BAD NAME" = "file";
                };
              };
              tsIface = evalWith {
                services.tailscale.interfaceName = "ts0";
                t3Connect = {
                  enable = true;
                  mesh = {
                    enable = true;
                    loginServer = "https://mesh.example.net";
                  };
                };
              };
              badBind = evalWith {
                t3Connect = {
                  enable = true;
                  bind = "not an address";
                };
              };
              # A long-lived guest: a fixed node name and an extra unit restarted with the server.
              fixed = evalWith {
                t3Connect = {
                  enable = true;
                  mesh = {
                    enable = true;
                    loginServer = "https://mesh.example.net";
                    hostname = "node-a";
                  };
                  ready.restartUnits = [ "home-manager-user.service" ];
                };
              };
              badHostname = evalWith {
                t3Connect = {
                  enable = true;
                  mesh = {
                    enable = true;
                    loginServer = "https://mesh.example.net";
                    hostname = "Bad Name";
                  };
                };
              };
              badRestart = evalWith {
                t3Connect = {
                  enable = true;
                  ready.restartUnits = [ "a.service; reboot" ];
                };
              };
              svc = sys: sys.config.systemd.services;
              # An absent option or unit reads as the default, so a missing behaviour fails its case
              # instead of aborting the whole evaluation.
              genOf = sys: key: sys.config.t3Connect.generated.${key} or "";
              has = lib.hasInfix;
              cases = {
                "disabled adds no t3-serve" = !(svc off ? t3-serve);
                "disabled adds no ready poller" = !(svc off ? t3-ready) && !(off.config.systemd.timers ? t3-ready);
                "disabled leaves tailscale off" = !off.config.services.tailscale.enable;
                "enabled adds t3-serve, the poller and the node rename" =
                  (svc on ? t3-serve)
                  && (svc on ? t3-ready)
                  && (on.config.systemd.timers ? t3-ready)
                  && (svc on ? t3-hostname);
                "server binds :: on port 3773 with the base dir" =
                  has "--host ::" (genOf on "run")
                  && has "--port 3773" (genOf on "run")
                  && has "--base-dir /home/user/.t3" (genOf on "run");
                "each credential is exported from the credentials directory" =
                  has ''export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$CREDENTIALS_DIRECTORY/claude-oauth-token")"'' (
                    genOf on "run"
                  );
                "credentials are loaded from the secrets directory" =
                  get on [ "systemd" "services" "t3-serve" "serviceConfig" "LoadCredential" ] null
                  == [ "claude-oauth-token:/run/secrets/claude-oauth-token" ];
                "seed enables linked environments" = has ".linkedEnvironmentsEnabled = true" (genOf on "seed");
                "seed adds opencode enabled and codex off" =
                  has ''.providerInstances["opencode"] //= {"driver": "opencode", "enabled": true}'' (genOf on "seed")
                  && has ''.providerInstances["codex"] //= {"driver": "codex", "enabled": false}'' (genOf on "seed");
                "providers.opencode = false seeds it off" =
                  has ''.providerInstances["opencode"] //= {"driver": "opencode", "enabled": false}'' (
                    genOf userOff "seed"
                  );
                "mesh join reads the key from the secrets directory" =
                  on.config.services.tailscale.enable
                  && on.config.services.tailscale.authKeyFile == "/run/secrets/tailscale-authkey";
                "mesh join resets prefs and never advertises a tag" =
                  builtins.elem "--reset" on.config.services.tailscale.extraUpFlags
                  && builtins.elem "--login-server=https://mesh.example.net" on.config.services.tailscale.extraUpFlags
                  && !(lib.any (f: has "advertise-tags" f) on.config.services.tailscale.extraUpFlags);
                "join waits for the ready marker" =
                  get on [ "systemd" "services" "tailscaled-autoconnect" "unitConfig" "ConditionPathExists" ] null
                  == "/run/secrets/.ready";
                "the server starts after the join and the rename, but does not require them" =
                  builtins.elem "tailscaled-autoconnect.service" (
                    get on [ "systemd" "services" "t3-serve" "after" ] [ ]
                  )
                  && builtins.elem "t3-hostname.service" (get on [ "systemd" "services" "t3-serve" "after" ] [ ])
                  && !(lib.any (u: builtins.elem u (get on [ "systemd" "services" "t3-serve" "requires" ] [ ])) [
                    "tailscaled-autoconnect.service"
                    "t3-hostname.service"
                  ]);
                "poller checks the marker every 5 s" =
                  get on [ "systemd" "timers" "t3-ready" "timerConfig" "OnBootSec" ] null == "5s"
                  && get on [ "systemd" "timers" "t3-ready" "timerConfig" "OnUnitInactiveSec" ] null == "5s"
                  && has "/run/secrets/.ready" (genOf on "ready");
                "the port opens on the mesh interface only" =
                  get on [ "networking" "firewall" "interfaces" "tailscale0" "allowedTCPPorts" ] [ ] == [ 3773 ]
                  && !(builtins.elem 3773 on.config.networking.firewall.allowedTCPPorts);
                "without mesh there is no tailscale and no node rename" =
                  !noMesh.config.services.tailscale.enable && !(svc noMesh ? t3-hostname);
                "the t3-pair helper mints a code and prints only the code" =
                  has "t3 pair --base-dir /home/user/.t3" (genOf on "pair")
                  && has "sed -n 's/^Token: //p'" (genOf on "pair")
                  && builtins.any (p: lib.getName p == "t3-pair") (get on [ "environment" "systemPackages" ] [ ]);
                "the poller restarts the server, the join and the rename in one call" =
                  has "systemctl restart --no-block t3-serve.service tailscaled-autoconnect.service t3-hostname.service" (
                    genOf on "ready"
                  );
                "t3-pair refuses to run as another user" = has ''[ "$(id -un)" = "user" ]'' (genOf on "pair");
                "the seed keeps an app-side opt-out of linked environments" =
                  has ''if has("linkedEnvironmentsEnabled") then . else'' (genOf on "seed");
                "the port follows the tailscale interface name" =
                  get tsIface [ "networking" "firewall" "interfaces" "ts0" "allowedTCPPorts" ] [ ] == [ 3773 ];
                "a fixed mesh hostname is applied and the injected file is not read" =
                  has "tailscale set --hostname=node-a" (genOf fixed "hostname")
                  && !(has "/run/secrets/hostname" (genOf fixed "hostname"));
                "without mesh.hostname the node is named from the injected file" = has "/run/secrets/hostname" (
                  genOf on "hostname"
                );
                "extra restart units join the poller's single call" =
                  has "systemctl restart --no-block t3-serve.service tailscaled-autoconnect.service t3-hostname.service home-manager-user.service" (
                    genOf fixed "ready"
                  );
                "a mesh hostname that is not a DNS label is refused" = evalFails badHostname;
                "a restart unit that is not a unit name is refused" = evalFails badRestart;
                "a firewall that is off is refused" = evalFails noFirewall;
                "a credential name that is not an identifier is refused" = evalFails badCred;
                "a bind that is not an address fails evaluation" = evalFails badBind;
              };
              failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
            in
            assert lib.assertMsg (failed == [ ]) "t3-connect-eval failed: ${lib.concatStringsSep "; " failed}";
            pkgs.writeText "t3-connect-eval" (
              builtins.unsafeDiscardStringContext (
                lib.concatMapStringsSep "\n" (sys: sys.config.system.build.toplevel.drvPath) [
                  off
                  on
                  noMesh
                ]
              )
            );

          # nixosModules.t3-sandbox: the one-import guest. It follows the sandbox's user and tools, turns the
          # mesh on, evaluates to a whole system, and fails without a login server.
          t3-sandbox-eval =
            let
              evalWith =
                extra:
                nixpkgs.lib.nixosSystem {
                  modules = [
                    self.nixosModules.t3-sandbox
                    stubSystem
                    {
                      nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
                    }
                    extra
                  ];
                };
              server = {
                t3Connect.mesh.loginServer = "https://mesh.example.net";
              };
              basic = evalWith server;
              custom = evalWith (
                server
                // {
                  sandbox = {
                    user = "dev";
                    tools = [
                      "claude"
                      "opencode"
                    ];
                  };
                }
              );
              noServer = evalWith { };
              ok =
                basic.config.t3Connect.enable
                && basic.config.t3Connect.mesh.enable
                && basic.config.t3Connect.user == "user"
                && basic.config.t3Connect.harnesses == [ "claude" ]
                && basic.config.systemd.services ? t3-serve
                && custom.config.t3Connect.user == "dev"
                &&
                  custom.config.t3Connect.harnesses == [
                    "claude"
                    "opencode"
                  ]
                && custom.config.users.users.dev.isNormalUser
                && evalFails noServer;
            in
            assert lib.assertMsg ok "t3-sandbox-eval failed";
            pkgs.writeText "t3-sandbox-eval" (
              builtins.unsafeDiscardStringContext (
                basic.config.system.build.toplevel.drvPath + custom.config.system.build.toplevel.drvPath
              )
            );

          # The generated seed script, run for real with jq: a missing file is created with the seed, a
          # user's edits (an instance switched off, the linked beta switched off, a key of their own)
          # survive a second run, and a provider name with a hyphen cannot change the jq program.
          t3-connect-seed =
            let
              sys = nixpkgs.lib.nixosSystem {
                modules = [
                  self.nixosModules.t3-connect
                  stubSystem
                  {
                    nixpkgs.overlays = [ self.overlays.default ];
                    users.users.user.isNormalUser = true;
                    t3Connect = {
                      enable = true;
                      baseDir = "/tmp/t3seed";
                      harnesses = [
                        "claude"
                        "opencode"
                      ];
                      providers = {
                        codex = false;
                        "my-driver" = true;
                      };
                    };
                  }
                ];
              };
              script = pkgs.writeShellScript "seed" sys.config.t3Connect.generated.seed;
            in
            pkgs.runCommand "t3-connect-seed"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.bash
                  pkgs.coreutils
                ];
              }
              ''
                set -e
                f=/tmp/t3seed/userdata/settings.json
                bash ${script}
                jq -e '.linkedEnvironmentsEnabled == true
                  and .providerInstances.opencode.enabled == true
                  and .providerInstances.codex.enabled == false
                  and .providerInstances["my-driver"].enabled == true' "$f"
                jq '.providerInstances.opencode.enabled = false | .linkedEnvironmentsEnabled = false | .mine = "kept"' "$f" > "$f.edit"
                mv "$f.edit" "$f"
                bash ${script}
                jq -e '.providerInstances.opencode.enabled == false
                  and .linkedEnvironmentsEnabled == false
                  and .mine == "kept"' "$f"
                touch "$out"
              '';

          # homeModules.t3-connect-delegator: evaluated with a stub for home-manager's option, since this
          # flake has no home-manager input. Enabled installs t3-link-vm and t3-unlink-vm; disabled installs nothing.
          t3-connect-delegator-eval =
            let
              pkgsOv = import nixpkgs {
                inherit system;
                overlays = [ self.overlays.default ];
              };
              evalWith =
                enable: reaper:
                lib.evalModules {
                  modules = [
                    (import ./modules/t3-connect/delegator.nix { inherit self; })
                    {
                      options.home.packages = lib.mkOption {
                        type = lib.types.listOf lib.types.package;
                        default = [ ];
                      };
                      options.home.homeDirectory = lib.mkOption { type = lib.types.str; };
                      options.assertions = lib.mkOption {
                        type = lib.types.listOf lib.types.attrs;
                        default = [ ];
                      };
                      options.launchd.agents = lib.mkOption {
                        type = lib.types.attrsOf lib.types.attrs;
                        default = { };
                      };
                      config.home.homeDirectory = "/home/t";
                      config._module.args.pkgs = pkgsOv;
                      config.t3Connect.delegator.enable = enable;
                      config.t3Connect.delegator.reaper.enable = reaper;
                      config.t3Connect.delegator.reaper.host = "vmhost";
                    }
                  ];
                };
              on = evalWith true false;
              off = evalWith false false;
              withReaper = evalWith true true;
              agent = withReaper.config.launchd.agents.t3-run-vm-reap.config;
              ok =
                map lib.getName on.config.home.packages == [
                  "t3-link-vm"
                  "t3-unlink-vm"
                ]
                && off.config.home.packages == [ ]
                # the reaper is off unless asked for, and then runs --reap-only at load and every 300 s
                && on.config.launchd.agents == { }
                && agent.RunAtLoad
                && agent.StartInterval == 300
                && builtins.elem "--reap-only" agent.ProgramArguments;
            in
            assert lib.assertMsg ok "t3-connect-delegator-eval failed";
            pkgs.writeText "t3-connect-delegator-eval" "ok";

          # t3-link-vm against a fake ssh and a fake t3 (tests/t3-link-vm.sh): version skew is refused
          # before a code is minted, the code is never printed, and the default link is full access.
          t3-link-vm =
            let
              stubT3 = pkgs.writeShellScriptBin "t3" "";
              linkVm = import ./modules/t3-connect/link-vm.nix {
                inherit pkgs;
                t3 = stubT3;
              };
              unlinkVm = import ./modules/t3-connect/unlink-vm.nix {
                inherit pkgs;
                t3 = stubT3;
              };
            in
            pkgs.runCommand "t3-link-vm-test"
              {
                nativeBuildInputs = [
                  linkVm
                  unlinkVm
                  pkgs.bash
                  pkgs.jq
                  pkgs.gnused
                  pkgs.coreutils
                ];
              }
              ''
                bash ${./tests/t3-link-vm.sh} ${linkVm}/bin/t3-link-vm
                bash ${./tests/t3-unlink-vm.sh} ${unlinkVm}/bin/t3-unlink-vm
                touch "$out"
              '';

          # t3-run-vm: the whole link life cycle against a fake VM host and a fake app CLI
          # (tests/t3-run-vm.sh). The host-side start script it runs is not in this repo.
          t3-run-vm =
            let
              stubT3 = pkgs.writeShellScriptBin "t3" "";
              runVmWrapper = import ./modules/t3-connect/run-vm.nix {
                inherit pkgs;
                t3 = stubT3;
              };
            in
            pkgs.runCommand "t3-run-vm-test"
              {
                nativeBuildInputs = [
                  runVmWrapper
                  pkgs.bash
                  pkgs.busybox
                  pkgs.curl
                  pkgs.jq
                  pkgs.gnused
                  pkgs.coreutils
                ];
              }
              ''
                bash ${./tests/t3-run-vm.sh} ${runVmWrapper}/bin/t3-run-vm
                touch "$out"
              '';

          # nixosModules.t3-connect-host: the bridge, the taps and the rules as specified. Disabled adds
          # none of them; a bridge named br-* (trusted by docker hosts) is refused.
          t3-connect-host-eval =
            let
              evalWith =
                extra:
                nixpkgs.lib.nixosSystem {
                  modules = [
                    self.nixosModules.t3-connect-host
                    stubSystem
                    {
                    }
                    extra
                  ];
                };
              off = evalWith { t3ConnectHost.enable = false; };
              on = evalWith { t3ConnectHost.enable = true; };
              custom = evalWith {
                t3ConnectHost = {
                  enable = true;
                  bridge = {
                    name = "sbx0";
                    address = "192.168.99.1";
                    subnet = "192.168.99.0/24";
                  };
                  tapMatch = "sbx-*";
                  blockedRanges = [ "10.0.0.0/8" ];
                };
              };
              noFirewall = evalWith {
                networking.firewall.enable = false;
                t3ConnectHost.enable = true;
              };
              withNftables = evalWith {
                networking.nftables.enable = true;
                t3ConnectHost.enable = true;
              };
              noV6 = evalWith {
                networking.enableIPv6 = false;
                t3ConnectHost.enable = true;
              };
              badName = evalWith {
                t3ConnectHost = {
                  enable = true;
                  bridge.name = "br-guests";
                };
              };
              longName = evalWith {
                t3ConnectHost = {
                  enable = true;
                  bridge.name = "a-bridge-name-over-15";
                };
              };
              rules = sys: get sys [ "networking" "firewall" "extraCommands" ] "";
              stop = sys: get sys [ "networking" "firewall" "extraStopCommands" ] "";
              has = lib.hasInfix;
              cases = {
                "disabled adds no bridge" = !(off.config.systemd.network.netdevs ? "20-t3br0");
                "disabled adds no rules" = !(has "t3-fwd" (rules off));
                "enabled creates the bridge" =
                  get on [ "systemd" "network" "netdevs" "20-t3br0" "netdevConfig" "Kind" ] null == "bridge";
                "the host gets the gateway address" =
                  get on [ "systemd" "network" "networks" "20-t3br0" "address" ] [ ] == [ "192.168.83.1/24" ];
                "forwarding is on for the bridge only" =
                  get on [ "systemd" "network" "networks" "20-t3br0" "networkConfig" "IPv4Forwarding" ] false == true
                  &&
                    get on [ "systemd" "network" "networks" "20-t3br0" "networkConfig" "IPv6Forwarding" ] true == false;
                "matching taps join the bridge with isolated ports" =
                  get on [ "systemd" "network" "networks" "21-t3-taps" "networkConfig" "Bridge" ] null == "t3br0"
                  && get on [ "systemd" "network" "networks" "21-t3-taps" "bridgeConfig" "Isolated" ] false == true
                  && get on [ "systemd" "network" "networks" "21-t3-taps" "matchConfig" "Name" ] null == "vm-*";
                "input drops new guest connections but lets replies in" =
                  has "iptables -A t3-in -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" (rules on)
                  && has "iptables -A t3-in -j DROP" (rules on)
                  && has "iptables -I INPUT 1 -i t3br0 -j t3-in" (rules on);
                "forward drops spoofed sources first" =
                  has "iptables -t mangle -A t3-fwd ! -s 192.168.83.0/24 -j DROP" (rules on);
                "forward drops every blocked range, then returns to filter" =
                  lib.all (net: has "iptables -t mangle -A t3-fwd -d ${net} -j DROP" (rules on)) [
                    "10.0.0.0/8"
                    "100.64.0.0/10"
                    "169.254.0.0/16"
                    "172.16.0.0/12"
                    "192.168.0.0/16"
                    "224.0.0.0/3"
                  ]
                  && has "iptables -t mangle -A t3-fwd -j RETURN" (rules on);
                "the return comes after the drops" =
                  let
                    r = rules on;
                    parts = lib.splitString "iptables -t mangle -A t3-fwd -j RETURN" r;
                  in
                  has "-d 100.64.0.0/10 -j DROP" (builtins.elemAt parts 0);
                "routing is on globally, because replies enter on the uplink" =
                  get on [ "boot" "kernel" "sysctl" "net.ipv4.ip_forward" ] null == 1
                  && get off [ "boot" "kernel" "sysctl" "net.ipv4.ip_forward" ] null != 1;
                "forward jumps sit at position 1" = has "iptables -t mangle -I FORWARD 1 -i t3br0 -j t3-fwd" (
                  rules on
                );
                "nat masquerades the guest subnet only" =
                  has "iptables -t nat -A t3-nat ! -d 192.168.83.0/24 -j MASQUERADE" (rules on)
                  && has "iptables -t nat -A POSTROUTING -s 192.168.83.0/24 -j t3-nat" (rules on);
                "ipv6 is dropped as a backstop" =
                  has "ip6tables -I FORWARD 1 -i t3br0 -j DROP" (rules on)
                  && has "ip6tables -A t3-in6 -j DROP" (rules on);
                "stop removes every chain and jump" = lib.all (frag: has frag (stop on)) [
                  "iptables -X t3-in"
                  "iptables -t mangle -X t3-fwd"
                  "iptables -t nat -X t3-nat"
                  "ip6tables -X t3-in6"
                  "iptables -t mangle -D FORWARD -i t3br0 -j t3-fwd"
                ];
                "options drive the rules" =
                  has "iptables -I INPUT 1 -i sbx0 -j t3-in" (rules custom)
                  && has "iptables -t mangle -A t3-fwd ! -s 192.168.99.0/24 -j DROP" (rules custom)
                  && has "iptables -t mangle -A t3-fwd -d 10.0.0.0/8 -j DROP" (rules custom)
                  && !(has "100.64.0.0/10" (rules custom))
                  && get custom [ "systemd" "network" "networks" "21-t3-taps" "matchConfig" "Name" ] null == "sbx-*";
                "guests are dropped before DNAT can hide a host address" =
                  has "iptables -t mangle -I PREROUTING 1 -i t3br0 -m conntrack --ctstate NEW -m addrtype --dst-type LOCAL -j DROP" (
                    rules on
                  );
                "no new connection into a guest" =
                  has "iptables -t mangle -I FORWARD 1 -o t3br0 -m conntrack --ctstate NEW -j DROP" (rules on);
                "the guest subnet is dropped whatever the blocked ranges are" =
                  has "iptables -t mangle -A t3-fwd -d 192.168.99.0/24 -j DROP" (rules custom)
                  && has "iptables -t mangle -A t3-fwd -d 192.168.83.0/24 -j DROP" (rules on);
                "filter FORWARD accepts what mangle let through, at position 1" =
                  has "iptables -I FORWARD 1 -i t3br0 -j ACCEPT" (rules on);
                "dhcpcd is kept off the bridge and the taps" =
                  builtins.elem "t3br0" (get on [ "networking" "dhcpcd" "denyInterfaces" ] [ ])
                  && builtins.elem "vm-*" (get on [ "networking" "dhcpcd" "denyInterfaces" ] [ ]);
                "the bridge does not stall boot waiting for carrier" =
                  get on [ "systemd" "network" "networks" "20-t3br0" "linkConfig" "RequiredForOnline" ] null == "no";
                "no ip6tables rules when IPv6 is off" = !(has "ip6tables" (rules noV6));
                "a host without the iptables firewall is refused" = evalFails noFirewall && evalFails withNftables;
                "a bridge named br-* fails evaluation" = evalFails badName;
                "a bridge name over 15 characters fails evaluation" = evalFails longName;
              };
              failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
            in
            assert lib.assertMsg (
              failed == [ ]
            ) "t3-connect-host-eval failed: ${lib.concatStringsSep "; " failed}";
            pkgs.writeText "t3-connect-host-eval" (
              builtins.unsafeDiscardStringContext (
                lib.concatMapStringsSep "\n" (sys: sys.config.system.build.toplevel.drvPath) [
                  off
                  on
                  custom
                ]
              )
            );

          # Unit test for the plugin marketplace normalizer: evaluated here (the sandbox has no nix),
          # then compared by the suite's jq checks. See tests/agent-plugins-suite.sh.
          agent-plugins-lib =
            let
              fix = "${./tests/fixtures/agent-plugins}";
              ps = (import ./modules/home/agent-plugins-lib.nix { inherit lib; }).normalize {
                src = fix;
                exclude = [ "skipme" ];
              };
              records = pkgs.writeText "agent-plugins.json" (
                builtins.toJSON {
                  names = map (p: p.name) ps;
                  byName = lib.listToAttrs (map (p: lib.nameValuePair p.name p) ps);
                }
              );
            in
            pkgs.runCommand "agent-plugins-lib"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.jq
                ];
              }
              ''
                bash ${./tests/agent-plugins-suite.sh} ${records} ${fix}
                touch "$out"
              '';
        }
      );

      # Live boot test for nixosModules.sandbox (needs sandy, vfkit or qemu; not run in CI).
      apps = lib.genAttrs (systems ++ [ "aarch64-darwin" ]) (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          test-sandbox = {
            type = "app";
            program = "${pkgs.writeShellScript "test-sandbox" (builtins.readFile ./tests/sandbox-boot.sh)}";
          };
        }
      );

      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}

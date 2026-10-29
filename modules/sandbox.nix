# modules/sandbox.nix
# nixosModules.sandbox: a basic user in a bare guest, preconfigured. It creates one ordinary account
# (`sandbox.user`, default "user") with a minimal home, installs the chosen harnesses and a few
# utilities, and runs the compression proxy as a DynamicUser service. No home-manager: the harness
# config is written once into the home as plain, user-owned, writable files, the way a person who
# had run each tool once would have them.
#
# sandy's guest autologins root and runs the job as root, so run the job as the user with
#   runuser -u user -- <command>
# which keeps the injected environment (secrets) and sets HOME for that user.
#
# Not set: any model or provider. Those are the job's choice.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sandbox;
  has = tool: builtins.elem tool cfg.tools;
  shared = import ./shared.nix;
  inherit (shared) headroomArgs headroomEnv codebaseMemoryMcpCmd;
  home = "/home/${cfg.user}";
  routeClaude = cfg.compression && has "claude";

  json = name: value: pkgs.writeText name (builtins.toJSON value);

  # Files of the minimal home, by path relative to $HOME. Each tool gets exactly what a user would
  # have after first use: onboarding done, the code-graph MCP server registered, and the traffic
  # to Anthropic or the tool vendor that a sandbox does not want switched off.
  files =
    lib.optionalAttrs (has "claude") {
      ".claude.json" = json "claude.json" {
        hasCompletedOnboarding = true;
        mcpServers.codebase-memory-mcp = {
          type = "stdio";
          command = "codebase-memory-mcp";
          args = [ ];
          alwaysLoad = true;
        };
      };
      ".claude/settings.json" = json "claude-settings.json" {
        env = {
          CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
          DISABLE_TELEMETRY = "1";
          DISABLE_ERROR_REPORTING = "1";
          DISABLE_UPDATES = "1";
          CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1";
        };
      };
    }
    // lib.optionalAttrs (has "opencode") {
      ".config/opencode/opencode.json" = json "opencode.json" {
        "$schema" = "https://opencode.ai/config.schema.json";
        autoupdate = false;
        mcp.codebase-memory-mcp = {
          type = "local";
          command = codebaseMemoryMcpCmd;
        };
      };
    }
    // lib.optionalAttrs (has "codex") {
      ".codex/config.toml" = pkgs.writeText "codex-config.toml" ''
        check_for_update_on_startup = false

        [analytics]
        enabled = false

        [feedback]
        enabled = false

        [mcp_servers.codebase-memory-mcp]
        command = "sh"
        args = ["-c", ${builtins.toJSON (builtins.elemAt codebaseMemoryMcpCmd 2)}]
      '';
    };

  # Every parent directory of a file, shallowest first, each owned by the user (tmpfiles creates
  # only the leaf of a `d` line, and would leave a missing parent owned by root).
  dirs = lib.unique (
    lib.concatMap (
      path:
      let
        parts = lib.init (lib.splitString "/" path);
      in
      lib.genList (n: lib.concatStringsSep "/" (lib.take (n + 1) parts)) (lib.length parts)
    ) (lib.attrNames files)
  );
in
{
  options.sandbox = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "The ordinary account the job runs as.";
    };

    tools = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "claude"
          "opencode"
          "codex"
        ]
      );
      default = [ "claude" ];
      description = "Which harnesses to install and preconfigure.";
    };

    compression = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the Headroom context-compression proxy and route Claude through it. The route is
        unconditional (the proxy is part of the image), so a stopped proxy stops Claude.
      '';
    };
  };

  config = {
    nixpkgs.overlays = [ self.overlays.default ];
    # claude-code is the only unfree package here.
    nixpkgs.config.allowUnfreePredicate = lib.mkDefault (pkg: lib.getName pkg == "claude-code");

    users.users.${cfg.user} = {
      isNormalUser = true;
      inherit home;
      shell = pkgs.bashInteractive;
    };

    # Minimal utility tooling: what an agent needs to read, search and fetch.
    environment.systemPackages = [
      pkgs.git
      pkgs.curl
      pkgs.jq
      pkgs.ripgrep
      pkgs.codebase-memory-mcp
    ]
    ++ lib.optional (has "claude") pkgs.claude-code
    ++ lib.optional (has "opencode") pkgs.opencode
    ++ lib.optional (has "codex") pkgs.codex;

    # `C` copies a file only when it is absent, so the user can edit it and it stays edited.
    systemd.tmpfiles.rules =
      map (dir: "d ${home}/${dir} 0755 ${cfg.user} users -") dirs
      ++ lib.mapAttrsToList (path: source: "C ${home}/${path} 0644 ${cfg.user} users - ${source}") files;

    environment.variables = lib.mkIf routeClaude { ANTHROPIC_BASE_URL = "http://127.0.0.1:8787"; };

    systemd.services.headroom-proxy = lib.mkIf cfg.compression {
      description = "Headroom compression proxy (anthropic backend)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        HOME = "/var/lib/headroom";
        # LiteLLM fetches its model-cost map from GitHub at start; a sandbox may have no network and
        # pays the connect timeout on every boot. This uses the map bundled with the pinned version.
        LITELLM_LOCAL_MODEL_COST_MAP = "True";
      }
      // headroomEnv;
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "headroom";
        Restart = "on-failure";
        RestartSec = 3;
        ExecStart = "${pkgs.agentic-tools}/bin/headroom proxy ${lib.concatStringsSep " " headroomArgs}";
      };
    };
  };
}

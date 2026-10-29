# modules/sandbox.nix
# nixosModules.sandbox: the thinnest agent sandbox. It ships the chosen harnesses with their config
# in system locations, so it works for whatever user the job runs as: no home-manager, no user
# account, no dotfiles to link. Compression runs as a DynamicUser service.
#
# What each tool reads (official docs, checked 2026-10-29):
#   claude  /etc/claude-code/managed-settings.json and managed-mcp.json (managed-mcp.json takes
#           exclusive control of MCP servers, so `claude mcp add` is refused)
#   codex   /etc/codex/config.toml
#   opencode  the file named by $OPENCODE_CONFIG
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
  routeClaude = cfg.compression && has "claude";

  # One stdio server, indexed on spawn so the graph is never empty.
  mcpServer = {
    type = "stdio";
    command = "codebase-memory-mcp";
    args = [ ];
    alwaysLoad = true;
  };

  claudeSettings = {
    env = {
      # No telemetry, error reports, update checks or surveys from a throwaway sandbox.
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      DISABLE_TELEMETRY = "1";
      DISABLE_ERROR_REPORTING = "1";
      DISABLE_UPDATES = "1";
      CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1";
    };
  };

  opencodeConfig = {
    "$schema" = "https://opencode.ai/config.schema.json";
    autoupdate = false;
    mcp.codebase-memory-mcp = {
      type = "local";
      command = codebaseMemoryMcpCmd;
    };
  };
in
{
  options.sandbox = {
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

    environment.etc = lib.mkMerge [
      (lib.mkIf (has "claude") {
        "claude-code/managed-settings.json".text = builtins.toJSON claudeSettings;
        "claude-code/managed-mcp.json".text = builtins.toJSON {
          mcpServers.codebase-memory-mcp = mcpServer;
        };
      })
      (lib.mkIf (has "opencode") {
        "agent-env/opencode.json".text = builtins.toJSON opencodeConfig;
      })
      (lib.mkIf (has "codex") {
        "codex/config.toml".text = ''
          check_for_update_on_startup = false

          [analytics]
          enabled = false

          [feedback]
          enabled = false

          [mcp_servers.codebase-memory-mcp]
          command = "sh"
          args = ["-c", ${builtins.toJSON (builtins.elemAt codebaseMemoryMcpCmd 2)}]
        '';
      })
    ];

    environment.variables = lib.mkMerge [
      (lib.mkIf (has "opencode") { OPENCODE_CONFIG = "/etc/agent-env/opencode.json"; })
      (lib.mkIf routeClaude { ANTHROPIC_BASE_URL = "http://127.0.0.1:8787"; })
    ];

    systemd.services.headroom-proxy = lib.mkIf cfg.compression {
      description = "Headroom compression proxy (anthropic backend)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        HOME = "/var/lib/headroom";
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

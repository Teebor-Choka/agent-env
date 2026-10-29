# The agentic environment: what runs inside an agent sandbox, independent of how the sandbox is
# built. One module installs the agentic CLIs (claude-code, opencode, codex, omp), writes their
# on-disk settings, wires the shared MCP servers, optionally persists session state and runs the
# Headroom compression proxy, and delivers plugins and skills through the home-manager modules in
# ./home. A VM, container or workstation sets `agentic = { user; tools; claudeProvider; ... }`.
#
# Platform: `isLinuxHost` is fixed per export (nixosModules.agentic = true, darwinModules.agentic =
# false), not read from `pkgs`: reading `pkgs.stdenv` or `pkgs.system` inside a module recurses
# infinitely during the module system's `_module.freeformType` discovery pass.
#
# Requires the home-manager NixOS or nix-darwin module (the settings land in
# `home-manager.users.<user>`). Host-specific mounts (a sessions share, a staged extensions tree)
# are named by `sessionsDir` and `extensionsDir`; whoever builds the sandbox provides them.
{ self, isLinuxHost }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.agentic;
  user = cfg.user;

  # Points Claude at the local headroom proxy when it is listening (fail-open: a dead proxy leaves
  # the real endpoint). Applied through the platform's own shell-init option (see its use below).
  proxyRoute = ''
    # headroom proxy: route Claude Code through the local compression proxy (127.0.0.1:8787).
    # Only when it is listening, so a stopped proxy never breaks a session.
    if ${pkgs.netcat}/bin/nc -z -w1 127.0.0.1 8787 2>/dev/null; then
      export ANTHROPIC_BASE_URL="http://127.0.0.1:8787"
      case "''${ANTHROPIC_MODEL:-}" in
        "" | *"[1m]") : ;;
        *) export ANTHROPIC_MODEL="''${ANTHROPIC_MODEL}[1m]" ;;
      esac
    fi
  '';

  # Tool-independent data that is slow to rebuild per boot (code-graph index, embedding models,
  # uv/headroom wheels); persisted under `sessionsDir` like the per-tool paths below.
  sharedDataPaths =
    map
      (path: {
        inherit path;
        kind = "dir";
      })
      [
        ".cache/codebase-memory-mcp"
        ".cache/fastembed"
        ".cache/huggingface"
        ".cache/uv"
      ];

  # Per-tool session state, relative to $HOME. With agentic.sessions, each path is a symlink into
  # `sessionsDir` at the same relative path, so it outlives a wiped /home. Session state only: ~/.claude.json, codex's auth.json, and nix-managed config stay in the
  # guest. Exception: opencode's data dir also holds its auth.json (absent here, where the key
  # comes from $OPENROUTER_API_KEY). "file" entries are append-only logs; a tool that replaced
  # one by rename would break its link.
  sessionPaths = {
    claude =
      map
        (path: {
          inherit path;
          kind = "dir";
        })
        [
          ".claude/projects"
          ".claude/file-history"
          ".claude/todos"
          ".claude/plans"
          ".claude/cache"
          ".claude/paste-cache"
          ".claude/session-env"
          ".claude/sessions"
        ]
      ++ [
        {
          path = ".claude/history.jsonl";
          kind = "file";
        }
      ];
    # opencode keeps sessions in opencode.db (SQLite), storage/, and snapshot/ under its data dir.
    opencode = [
      {
        path = ".local/share/opencode";
        kind = "dir";
      }
    ];
    codex = [
      {
        path = ".codex/sessions";
        kind = "dir";
      }
      {
        path = ".codex/archived_sessions";
        kind = "dir";
      }
      {
        path = ".codex/history.jsonl";
        kind = "file";
      }
    ];
    # omp's agent dir is ~/.omp/agent; its session store scans sessions/ and archived_sessions/.
    omp = [
      {
        path = ".omp/agent/sessions";
        kind = "dir";
      }
      {
        path = ".omp/agent/archived_sessions";
        kind = "dir";
      }
    ];
  };

  # Force-index wrapper for codebase-memory-mcp: harnesses without a Claude-Code-style
  # SessionStart hook (opencode, codex, omp) never trigger dotclaude's git-index hook, so the
  # graph would stay empty until someone runs index_repository by hand. Kick off an incremental
  # index in the background on every MCP server spawn (cheap on an already-indexed repo, same
  # reasoning as the git-reindex hook) then exec the real stdio server immediately -- never
  # blocks startup. Confirmed live: nodes/edges populate within a couple seconds of first spawn.
  #
  # Per-repo mkdir lock (same idiom as dotclaude's git-reindex hook): without it, every MCP
  # server spawn backgrounds a brand new index job with no guard against one already running.
  # Confirmed live -- a real opencode session over a few minutes stacked two concurrent `cce
  # index` processes, each pinning a CPU core on embedding computation, and the resulting
  # contention starved a THIRD cce serve's startup past opencode's 30s MCP timeout ("Operation
  # timed out after 30000ms"). The lock makes a repeat spawn skip straight to exec when an index
  # for this repo is already in flight, instead of queuing another one behind it.
  #
  # nice/ionice: codebase-memory-mcp is a single compiled binary (no multiprocessing pool observed,
  # unlike cce's embedding workers below) so hasn't actually shown this failure mode -- applied
  # anyway, on principle: a background bootstrap job should never be able to compete with the
  # foreground MCP server's own startup, consistently, not only where a crash happened to surface it.
  codebaseMemoryMcpCmd = [
    "sh"
    "-c"
    ''
      lock="$HOME/.cache/codebase-memory-index.$(printf '%s' "$PWD" | tr '/ ' '__').lock"
      mkdir -p "$HOME/.cache"
      if mkdir "$lock" 2>/dev/null; then
        (trap 'rmdir "$lock" 2>/dev/null || true' EXIT; nice -n 19 ionice -c3 codebase-memory-mcp cli index_repository "{\"repo_path\":\"$PWD\"}" >/dev/null 2>&1) &
      fi
      exec codebase-memory-mcp''
  ];

in
{
  options.agentic = {
    enable = lib.mkEnableOption "the agentic CLI bundle (claude-code / opencode + settings)";

    user = lib.mkOption {
      type = lib.types.str;
      description = "The user whose home-manager profile receives the harness settings.";
    };

    sessionsDir = lib.mkOption {
      type = lib.types.str;
      default = "sessions";
      description = ''
        Directory under $HOME that holds persisted session state when `sessions` is on. The caller
        mounts or creates it (for a microVM, a host-backed share).
      '';
    };

    extensionsDir = lib.mkOption {
      type = lib.types.str;
      default = "extensions";
      description = "Directory under $HOME that holds the staged host extensions for `linked`.";
    };

    extensionsPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Store snapshot of CLAUDE.md and the skills (`$out/CLAUDE.md`, `$out/skills`) that
        `extensions = "baked"` installs. Required for that mode.
      '';
    };

    tools = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "claude"
          "opencode"
          "codex"
          "omp"
        ]
      );
      default = [ "claude" ];
      description = "Which agentic CLIs to install and configure in the sandbox.";
    };

    claudeProvider = lib.mkOption {
      type = lib.types.enum [
        "anthropic"
        "openrouter"
      ];
      default = "anthropic";
      description = ''
        Claude Code routing. "anthropic" leaves it on the native subscription (interactive or token
        login); "openrouter" points ANTHROPIC_BASE_URL at the OpenRouter gateway and expects
        $OPENROUTER_API_KEY to be injected.
      '';
    };

    sessions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Persist each enabled tool's session state (sessionPaths: Claude transcripts, file history,
        todos, plans, prompt history; opencode's data dir; codex and omp sessions) onto the
        `sessionsDir`, symlinked in after the gitClone activation step. The caller must provide
        that directory.
      '';
    };

    extensions = lib.mkOption {
      type = lib.types.enum [
        "gitClone"
        "baked"
        "linked"
        "none"
      ];
      default = "gitClone";
      description = ''
        How the agentic EXTENSIONS (dotclaude settings/hooks, dotagents CLAUDE.md, the skills) reach
        the sandbox. The checkouts themselves are declared unconditionally in home.nix's
        home.gitClone (host and guest share one declaration -- see there); this option only
        decides whether a guest keeps or drops them:
        - "gitClone"/"none": inherit home.nix's clones as-is. Live/latest, but needs the forwarded
          SSH agent + network, so an isolated one-shot gets nothing (use "baked" or "linked" there).
        - "baked": overrides home.gitClone back to empty and installs a nix-store snapshot
          (`extensionsPackage`) with zero network/agent. Hermetic; the right
          choice for isolated sandboxes (e.g. opencode one-shots).
        - "linked": overrides home.gitClone back to empty and symlinks the host's own extension
          files (staged by the caller and mounted at `extensionsDir`) into
          the guest. No clone, no network, no agent; the VM must provide the share. Credentials
          are never staged (they arrive via secrets).
        skillLink and the ~/.claude/CLAUDE.md symlink stay in home.nix so the HOST keeps them too.
      '';
    };

    compression = lib.mkEnableOption ''
      the in-guest Headroom context-compression proxy for Claude Code. Runs headroom locally and
      routes Claude through it (fail-open: a dead proxy falls back to direct, never blocks a session).
      The proxy forwards the client's own auth header, so native-subscription and OAuth-token Claude
      both work. Compresses Claude only (opencode talks to OpenRouter directly). Tradeoff behind the
      custom base URL: Remote Control (/rc) is disabled and context caps at 200k unless a model with
      the [1m] suffix is selected (this wires [1m] onto an explicitly-set ANTHROPIC_MODEL). Requires
      claudeProvider = "anthropic"'';

    ephemeralDisk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether it is safe to wholesale-overwrite ~/.claude.json (and similar per-tool state
        files) rather than merge into them. true for a guest, where the disk is recreated fresh
        on every boot, so there is nothing accumulated to lose. The darwin host sets this false:
        its ~/.claude.json is Claude Code's real, persistent client state (oauthAccount, userID,
        per-project trust, onboarding/usage counters) and must never be clobbered — home.nix's
        own jq-merge activation script is the host's sole writer for that file instead.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # The overlay and the home-manager modules are always present, so a host that sets
      # `agentic.enable = false` still gets `home.agentPlugins`, `home.skillLink` and `home.swePlugin`.
      nixpkgs.overlays = [ self.overlays.default ];
      home-manager.sharedModules = [ self.homeModules.agentic ];
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          # uv/uvx runs the host's Headroom fallback below (no pkgs.agentic-tools on darwin) --
          # unconditional here since it's independent of which agentic.tools are enabled. Linux
          # guests run headroom from pkgs.agentic-tools instead, so they skip uv.
          environment.systemPackages = lib.optionals (!isLinuxHost) [ pkgs.uv ];
        }

        (lib.mkIf (builtins.elem "claude" cfg.tools) {
          environment.systemPackages = [ pkgs.claude-code ];
          # Claude Code needs this file or it forces interactive login even with credentials present;
          # also registers codebase-memory-mcp (stdio, alwaysLoad) globally, so the graph is
          # available from the first prompt in every project. Gated on ephemeralDisk: a wholesale
          # overwrite is only safe when there is no persistent ~/.claude.json state to lose (see the
          # option's own doc comment). mkIf, not optionalAttrs: optionalAttrs is strict (`if cond
          # then as else {}`) and forces `cond` immediately while this very module's own
          # config.agentic fixed point is still being computed -- self-referential infinite
          # recursion, confirmed empirically. mkIf returns a lazy marker instead, deferring the
          # condition to the option-merge pass, same as every other cfg.* reference in this file.
          home-manager.users.${user}.home.file = lib.mkIf cfg.ephemeralDisk {
            ".claude.json".text = builtins.toJSON {
              hasCompletedOnboarding = true;
              mcpServers.codebase-memory-mcp = {
                type = "stdio";
                command = "codebase-memory-mcp";
                args = [ ];
                alwaysLoad = true;
              };
            };
          };
        })

        (lib.mkIf (builtins.elem "opencode" cfg.tools) {
          environment.systemPackages = [ pkgs.opencode ];
          # $OPENROUTER_BASE_URL defaults to real OpenRouter; the compression branch fail-open-swaps it to
          # the local headroom OpenRouter proxy when that is up. mkBefore so the compression override
          # (mkAfter) wins. opencode reads it via the {env:...} ref below.
          environment.shellInit = lib.mkBefore ''
            export OPENROUTER_BASE_URL="''${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
          '';
          # Routed through OpenRouter with a single $OPENROUTER_API_KEY: deepseek for build, glm for the
          # advisor (plan/critique, no edit/bash) and tool subagents. apiKey must be wired explicitly or
          # opencode ignores $OPENROUTER_API_KEY and falls back to ADC/OAuth.
          home-manager.users.${user}.home.file.".config/opencode/opencode.json".text = builtins.toJSON {
            "$schema" = "https://opencode.ai/config.schema.json";
            model = "openrouter/deepseek/deepseek-v4.1-flash-1017";
            # opencode's own small_model default picks a hardcoded Anthropic model family for
            # title generation and other lightweight internal calls regardless of configured
            # provider (confirmed live: llm.provider=openrouter llm.model=anthropic/claude-haiku-4.5
            # with no small_model set) — this box has no Anthropic credentials for opencode, only
            # OpenRouter, so pin it to the same OpenRouter model already used for tool/advisor.
            small_model = "openrouter/z-ai/glm-5.3-flash";
            # codebase-memory-mcp was never registered for opencode (only Claude Code's .claude.json
            # had it) — confirmed live, opencode had no MCP servers configured at all. Same stdio
            # server, opencode's own "local" MCP type (array command).
            mcp = {
              codebase-memory-mcp = {
                type = "local";
                command = codebaseMemoryMcpCmd;
              };
            };
            provider.openrouter.options = {
              apiKey = "{env:OPENROUTER_API_KEY}";
              baseURL = "{env:OPENROUTER_BASE_URL}";
            };
            agent = {
              build = {
                mode = "primary";
                model = "openrouter/deepseek/deepseek-v4.1-flash-1017";
                permission.task = {
                  advisor = "allow";
                  tool = "allow";
                };
              };
              advisor = {
                description = "Consulted for plans and critiques; never edits";
                mode = "subagent";
                model = "openrouter/z-ai/glm-5.3-flash";
                permission = {
                  edit = "deny";
                  bash = "deny";
                };
              };
              tool = {
                model = "openrouter/z-ai/glm-5.3-flash";
              };
            };
          };
        })

        (lib.mkIf (builtins.elem "codex" cfg.tools) {
          environment.systemPackages = [ pkgs.codex ];
          # Same force-index MCP wiring as opencode above -- codex has no git-index equivalent of
          # its own either. ~/.codex/config.toml is Codex's OWN single global file (confirmed: Codex
          # CLI does not support per-project .mcp.json), so one entry here covers every project
          # codex touches; $PWD in the wrapped command still resolves per-invocation since the MCP
          # server subprocess inherits codex's own cwd at spawn time. TOML basic-string escaping is
          # a strict subset of JSON's, so builtins.toJSON produces a valid TOML string literal here too.
          home-manager.users.${user}.home.file.".codex/config.toml".text = ''
            [mcp_servers.codebase-memory-mcp]
            command = "sh"
            args = ["-c", ${builtins.toJSON (builtins.elemAt codebaseMemoryMcpCmd 2)}]
          '';
        })

        (lib.mkIf (builtins.elem "omp" cfg.tools) {
          environment.systemPackages = [ pkgs.omp ];
        })

        (lib.mkIf (cfg.claudeProvider == "openrouter") {
          # $OPENROUTER_API_KEY is exported from injected-env.sh via shellInit (order 1000); mkAfter
          # (1500) runs after that export exists. ANTHROPIC_API_KEY must be empty or Claude prefers it
          # over the auth token. Gateway model discovery loads the OpenRouter catalog.
          environment.shellInit = lib.mkAfter ''
            export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
            export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
            export ANTHROPIC_API_KEY=""
            export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
          '';
        })

        (lib.mkIf cfg.sessions (
          {
            # Module function so the inner `lib` carries home-manager's hm.dag extension.
            home-manager.users.${user} =
              { lib, ... }:
              {
                home.activation.linkSessions = lib.hm.dag.entryAfter [ "gitClone" ] (
                  lib.concatMapStrings (
                    { path, kind }:
                    let
                      link = ''"$HOME/${path}"'';
                      target = ''"$HOME/${cfg.sessionsDir}/${path}"'';
                    in
                    ''
                      $DRY_RUN_CMD mkdir -p "$(dirname ${target})" "$(dirname ${link})"
                      ${if kind == "dir" then "$DRY_RUN_CMD mkdir -p ${target}" else "$DRY_RUN_CMD touch ${target}"}
                      if [ -e ${link} ] && [ ! -L ${link} ]; then
                        ${
                          if kind == "dir" then
                            "$DRY_RUN_CMD cp -a ${link}/. ${target}/"
                          else
                            "$DRY_RUN_CMD sh -c 'cat \"$1\" >> \"$2\"' _ ${link} ${target}"
                        }
                        $DRY_RUN_CMD rm -rf ${link}
                      fi
                      $DRY_RUN_CMD ln -sfn ${target} ${link}
                    ''
                  ) (sharedDataPaths ++ lib.concatMap (tool: sessionPaths.${tool} or [ ]) cfg.tools)
                );
              };
          }
          # The links point into the share, so activation must not run before it mounts: mkdir into
          # an unmounted sessions directory lands on /home and is then shadowed. systemd.* has no darwin
          # equivalent (a hard error even under mkIf false), hence the plain `if` on isLinuxHost.
          // (
            if isLinuxHost then
              {
                systemd.services."home-manager-${user}".unitConfig.RequiresMountsFor = [
                  "/home/${user}/${cfg.sessionsDir}"
                ];
              }
            else
              { }
          )
        ))

        # Extensions via gitClone (default): the dotclaude/dotagents/skills-src/hoprnet-skills
        # checkouts themselves are declared unconditionally in home.nix's home.gitClone now -- host
        # and every guest share that one declaration (see home.nix for why). Nothing to add here for
        # this mode; "gitClone" and "none" both just inherit home.nix's clones. "baked" below is the
        # only mode that suppresses them.

        # Extensions baked into the store (for isolated sandboxes with no agent/network): install a
        # read-only snapshot of CLAUDE.md + the skills from `extensionsPackage`, and clear
        # home.gitClone when that option exists (nix-vm) so a baked guest makes no network calls
        # at all for these checkouts (a caller's declaration is unconditional; this opts a guest back
        # out of it). Only the read-only bits are
        # symlinked, so ~/.claude stays writable for Claude's own credentials/projects. skillLink is
        # disabled for this guest so it does not fight the baked ~/.claude/skills.
        (lib.mkIf (cfg.extensions == "baked") {
          assertions = [
            {
              assertion = cfg.extensionsPackage != null;
              message = ''agentic.extensions = "baked" requires agentic.extensionsPackage.'';
            }
          ];
          home-manager.users.${user} =
            { options, lib, ... }:
            lib.mkMerge [
              {
                home.skillLink.enable = lib.mkForce false;
                home.file.".claude/skills".source = "${cfg.extensionsPackage}/skills";
                home.file.".claude/CLAUDE.md".source = "${cfg.extensionsPackage}/CLAUDE.md";
              }
              (lib.optionalAttrs (options.home ? gitClone) { home.gitClone = lib.mkForce { }; })
            ];
        })

        # Extensions linked from the host: the caller stages the allowlisted host files (never
        # .credentials.json or session data) and mounts them at `extensionsDir`; everything below
        # symlinks into it. ~/.config/agents carries AGENTS.md and the flattened skills, which the
        # caller's own activation then links to ~/.claude/{CLAUDE.md,skills}.
        # skillLink is off: the staged skills are already flat, and ~/.config/agents is a link.
        (lib.mkIf (cfg.extensions == "linked") (
          {
            home-manager.users.${user} =
              {
                config,
                options,
                lib,
                ...
              }:
              lib.mkMerge [
                (lib.optionalAttrs (options.home ? gitClone) {
                  # The caller's clones are host workspace (file:///Users/... + SSH); a guest has its
                  # workspace mounted from the host instead, and an unreachable clone stalls activation.
                  home.gitClone = lib.mkForce { };
                })
                {
                  home.skillLink.enable = lib.mkForce false;
                  home.file =
                    lib.genAttrs
                      [
                        ".config/agents"
                        ".claude/settings.json"
                        ".claude/hooks"
                        ".claude/commands"
                        ".claude/agents"
                        ".claude/output-styles"
                      ]
                      (path: {
                        source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/${cfg.extensionsDir}/${path}";
                      });
                }
              ];
          }
          // (
            if isLinuxHost then
              {
                systemd.services."home-manager-${user}".unitConfig.RequiresMountsFor = [
                  "/home/${user}/${cfg.extensionsDir}"
                ];
              }
            else
              { }
          )
        ))

        # In-guest Headroom compression: Claude -> an `anthropic`-backend proxy on 8787, run via uvx
        # (fetched at service start, needs network once per boot), fail-open -- a dead proxy falls
        # back to the real endpoint, never blocking a session. headroom forwards the client's own auth
        # header, so both native-subscription (agent) and OAuth (agent-bp) Claude work. Supersedes the
        # host-only claude-hr wrapper. opencode has NO proxy here -- see the comment below the opencode
        # tools branch for why (headroom-ai's openrouter backend is broken upstream).
        (lib.mkIf cfg.compression (
          lib.mkMerge [
            # Claude's proxy + route, only when the claude harness is installed.
            (lib.mkIf (builtins.elem "claude" cfg.tools) (
              {
                assertions = [
                  {
                    assertion = cfg.claudeProvider == "anthropic";
                    message = ''agentic.compression requires claudeProvider = "anthropic" for the Claude proxy (the anthropic backend does not front the OpenRouter gateway).'';
                  }
                ];
              }
              # Claude fail-open route; [1m] re-enables the 1M window (a custom base URL otherwise
              # caps at 200k), only appended to an explicitly-chosen model. nix-darwin declares
              # environment.shellInit but never writes it into zsh or bash (only fish reads it), so on
              # the host the route silently never applied while the proxy ran. Everywhere it goes in
              # the interactive init of zsh and bash (/etc/zshrc, /etc/bashrc): the shell-wide init
              # (zshenv, environment.shellInit) would export the URL into every script and probe the
              # port on every shell spawn. A headless `claude -p` therefore goes direct.
              // (
                if isLinuxHost then
                  { environment.interactiveShellInit = lib.mkAfter proxyRoute; }
                else
                  {
                    programs.zsh.interactiveShellInit = lib.mkAfter proxyRoute;
                    programs.bash.interactiveShellInit = lib.mkAfter proxyRoute;
                  }
              )
              # Plain if/else, not mkIf: picks which platform's service-manager option tree is ever
              # referenced at all. nix-darwin has no `systemd` attribute whatsoever (confirmed via
              # `builtins.hasAttr "systemd" darwinConfigurations.slipstream.config` -> false) --
              # assigning to it, even under mkIf false, is a hard "option does not exist" eval error
              # regardless of the runtime condition, since mkIf only tags a value for an option that
              # must already be declared. A plain if/else sidesteps this: only the chosen branch's
              # keys are ever constructed, so the other platform's path is never mentioned at all.
              // (
                if isLinuxHost then
                  {
                    systemd.services.headroom-proxy-anthropic = {
                      description = "Headroom compression proxy (anthropic backend, for Claude Code)";
                      wantedBy = [ "multi-user.target" ];
                      after = [ "network-online.target" ];
                      wants = [ "network-online.target" ];
                      serviceConfig = {
                        User = user;
                        Restart = "on-failure";
                        RestartSec = 3;
                        # --anthropic-pre-upstream-concurrency auto-detects to max(2, min(8, cpu_count)) —
                        # as low as 8 concurrent requests in the parse/compress/upstream-connect stage,
                        # the real bottleneck for many parallel sessions/subagents (same fix as the
                        # darwin launchd unit below). --limit-concurrency/--max-connections default to
                        # 1000/500 already. headroom comes from pkgs.agentic-tools (nix-packaged,
                        # Teebor-Choka/agent-env) rather than a per-boot `uvx --from` fetch.
                        ExecStart = "${pkgs.agentic-tools}/bin/headroom proxy --backend anthropic --port 8787 --limit-concurrency 2000 --max-connections 1000 --anthropic-pre-upstream-concurrency 256";
                        Environment = [
                          "HOME=/home/${user}"
                          "PATH=/run/current-system/sw/bin"
                          # No anonymous usage beacon from the proxy.
                          "HEADROOM_BEACON=off"
                        ];
                      };
                    };
                  }
                else
                  {
                    # darwin has no systemd; launchd.agents is nix-darwin's own system-level
                    # equivalent (distinct from home-manager's per-user launchd.agents -- same
                    # field names, but directly under serviceConfig, not a nested config.* key, and
                    # no separate "enable": presence in the attrset is what matters). No
                    # pkgs.agentic-tools here -- agent-env builds Linux only, headroom-ai ships
                    # no macOS wheel at all -- so this stays on the uvx fetch, same fixes as before:
                    # UV_MANAGED_PYTHON (launchd jobs get no PATH, so uvx falls back to Apple's
                    # ancient /usr/bin/python3) and --python 3.12 (uv's newest managed Python has no
                    # onnxruntime wheels yet).
                    launchd.agents.headroom-proxy-anthropic = {
                      serviceConfig = {
                        ProgramArguments = [
                          "${pkgs.uv}/bin/uvx"
                          "--python"
                          "3.12"
                          "--from"
                          "headroom-ai[proxy]==0.41.0"
                          "headroom"
                          "proxy"
                          "--backend"
                          "anthropic"
                          "--port"
                          "8787"
                          "--limit-concurrency"
                          "2000"
                          "--max-connections"
                          "1000"
                          "--anthropic-pre-upstream-concurrency"
                          "256"
                        ];
                        KeepAlive = true;
                        RunAtLoad = true;
                        EnvironmentVariables = {
                          HOME = "/Users/${user}";
                          UV_MANAGED_PYTHON = "1";
                          # No anonymous usage beacon from the proxy.
                          HEADROOM_BEACON = "off";
                        };
                        StandardOutPath = "/Users/${user}/Library/Logs/headroom/proxy-anthropic.log";
                        StandardErrorPath = "/Users/${user}/Library/Logs/headroom/proxy-anthropic.log";
                      };
                    };
                    # StandardOutPath/StandardErrorPath don't create their parent dir.
                    home-manager.users.${user}.home.file."Library/Logs/headroom/.keep".text = "";
                  }
              )
            ))
            # No openrouter-backend branch here (removed): headroom-ai 0.41.0's litellm-openrouter
            # streaming path hard-crashes on every request — "cannot import name 'CacheableResult'
            # from 'mcp.types'" — because headroom pins mcp<2.0.0 but this code path needs mcp>=2.x
            # (litellm's own declared floor is mcp>=2.2.0,<3). Confirmed live: the proxy opens the
            # stream (initial 200) then dies mid-stream on every single completion, regardless of
            # model; `uv --with 'mcp>=2.2,<3'` to force a compatible version is refused because it
            # directly conflicts with headroom-ai's own pin. No newer headroom-ai release exists
            # (0.41.0 is latest on PyPI) and no documented workaround. opencode goes straight to
            # real OpenRouter instead — see the mkBefore default above, which now just stands
            # unconditionally since there's no local proxy to fail open to. Revisit if headroom-ai
            # ships a fix.
          ]
        ))
      ]
    ))
  ];
}

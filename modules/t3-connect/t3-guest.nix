# modules/t3-connect/t3-guest.nix
# nixosModules.t3-guest: the image-side pieces of a T3 guest and nothing else. A system user with its
# own home, the t3 server and a readiness probe in the image, and an https credential helper for
# github.com. No service, no secret and no mesh: the builder that boots the guest starts `t3 serve`
# and injects credentials (sandy does so through its workload and identity profile). For a guest that
# runs and joins the mesh itself, import `t3-connect` instead.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.t3Guest;

  # Succeeds once an HTTP server answers on the loopback port with a status below 500: t3 replies 503
  # while it starts and 401 once auth is on, so readiness never rests on console text. It proves an
  # HTTP listener, not that t3's API or websocket is up.
  probeScript = ''
    port=''${1:-${toString cfg.readyProbe.port}}
    case "$port" in
      "" | *[!0-9]*) echo "t3-ready-probe: the port must be digits, got: $port" >&2; exit 2 ;;
    esac
    if [ "''${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      echo "t3-ready-probe: the port must be 1 to 65535, got: $port" >&2
      exit 2
    fi
    code=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/") || exit 1
    [ "$code" -ge 100 ] && [ "$code" -lt 500 ]
  '';

  # The token is never written to a git config: the helper reads it when git asks. gh takes GH_TOKEN
  # before GITHUB_TOKEN, so the helper does too; the credential file is for a unit that got the token
  # as a systemd credential instead of an environment variable.
  credentialScript = ''
    [ "$1" = get ] || exit 0
    tok=''${GH_TOKEN:-''${GITHUB_TOKEN:-}}
    [ -n "$tok" ] || tok=$(cat "''${CREDENTIALS_DIRECTORY:-/nonexistent}/gh-token" 2>/dev/null) || true
    [ -n "$tok" ] || exit 0
    echo username=x-access-token
    echo "password=$tok"
  '';
in
{
  options.t3Guest = {
    enable = lib.mkEnableOption "the image-side pieces of a T3 guest";

    user = lib.mkOption {
      type = lib.types.str;
      default = "t3";
      description = "System user that runs t3 and the harnesses it launches.";
    };

    home = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/t3";
      description = "Home of that user: t3's state and the harnesses' config directories live here.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.t3-server;
      defaultText = lib.literalExpression "pkgs.t3-server";
      description = ''
        The headless t3 build (`pkgs.t3-server` from `overlays.default`). Its wrapper provides claude, codex,
        git and gh. A consumer that passes its own `pkgs` (so the overlay is not applied) must set it.
      '';
    };

    readyProbe.port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
      description = "Loopback port `t3-ready-probe` checks when it gets no argument.";
    };

    git.credentialHelper = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Register an https credential helper for github.com that answers with `GH_TOKEN`, else `GITHUB_TOKEN`,
        else the `gh-token` systemd credential, so `git` and `gh` clone private repos with the injected token.
      '';
    };

    generated = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      default = {
        probe = probeScript;
        credential = credentialScript;
      };
      description = "Script texts the module generates, for the evaluation checks.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" (toString cfg.home);
        message = "t3Guest.home must be an absolute path.";
      }
      {
        assertion = builtins.match "[a-z_][a-z0-9_-]*" cfg.user != null;
        message = "t3Guest.user must be a plain login name (lowercase letters, digits, - and _).";
      }
    ];

    nixpkgs.overlays = [ self.overlays.default ];

    users.groups.${cfg.user} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.home;
      createHome = true;
    };

    environment.systemPackages = [
      cfg.package
      (pkgs.writeShellScriptBin "t3-ready-probe" probeScript)
    ];

    programs.git = lib.mkIf cfg.git.credentialHelper {
      enable = true;
      config.credential."https://github.com".helper =
        "!${pkgs.writeShellScript "git-credential-gh-token" credentialScript}";
    };
  };
}

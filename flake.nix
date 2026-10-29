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
      darwinModules.agentic = import ./modules/agentic.nix {
        inherit self;
        isLinuxHost = false;
      };
      # home.agentPlugins, home.skillLink, home.swePlugin. Also registered by the modules above.
      homeModules.agentic = ./modules/home;

      packages = forEachSystem (system: {
        default = agenticToolsBySystem.${system};
        agentic-tools = agenticToolsBySystem.${system};
      });

      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          build = agenticToolsBySystem.${system};

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

      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}

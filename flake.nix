{
  description = "Nix packaging for agentic-tooling PyPI packages with no nixpkgs equivalent (headroom-ai, code-context-engine)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

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
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # headroom-ai and its fastembed/onnxruntime chain ship no macOS wheel (confirmed:
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
              python = pkgs.python312;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  pyproject-build-systems.overlays.wheel
                  overlay
                ]
              );
        in
        # One combined environment carrying both CLIs on PATH (headroom, cce, and their
        # own entry-point scripts) -- both tools are always installed together on every
        # guest that wants either (see agentic.nix in the consuming flake), so there is
        # no need to split this into a multi-member uv workspace for independent
        # packaging.
        pythonSet.mkVirtualEnv "agentic-tools-env" workspace.deps.default;

      agenticToolsBySystem = forEachSystem mkAgenticTools;
    in
    {
      packages = forEachSystem (system: {
        default = agenticToolsBySystem.${system};
        agentic-tools = agenticToolsBySystem.${system};
      });

      checks = forEachSystem (system: {
        build = agenticToolsBySystem.${system};
      });

      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}

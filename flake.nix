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

      # headroom-ai ships no macOS wheel (confirmed: PyPI only publishes
      # manylinux_2_28_x86_64 for 0.41.0) -- this flake only ever needs to run on the
      # x86_64-linux dev microVM guests that actually install these tools, so there is
      # no multi-system matrix to maintain here.
      system = "x86_64-linux";
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

      # One combined environment carrying both CLIs on PATH (headroom, cce, and their
      # own entry-point scripts) -- both tools are always installed together on every
      # guest that wants either (see agentic.nix in the consuming flake), so there is no
      # need to split this into a multi-member uv workspace for independent packaging.
      agenticTools = pythonSet.mkVirtualEnv "agentic-tools-env" workspace.deps.default;
    in
    {
      packages.${system} = {
        default = agenticTools;
        agentic-tools = agenticTools;
      };

      checks.${system}.build = agenticTools;

      formatter.${system} = pkgs.nixfmt;
    };
}

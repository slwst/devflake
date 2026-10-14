{
  description = "my-project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # The agent tooling (herdr, beads, openspec, claude, ...) is pinned by devflake's own lock;
    # `nix flake update devflake` upgrades it.
    devflake.url = "github:slwst/devflake";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      devflake,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # The project's build, e.g. buildGoApplication, buildNpmPackage, crane's buildPackage.
        # packages.default = ...;

        # `nix flake check` is the gate agents run before merging: tests and linters go here,
        # built offline in the Nix sandbox.
        checks = { };

        devShells.default = devflake.lib.mkShell {
          inherit pkgs;
          # Label of the project's herdr workspace, and the prefix its agents are named with
          name = "my-project";
          # The herdr session that workspace lives in. The default is shared with every other
          # devflake project on the host, so one `herdr` shows them all. Uncomment for a session
          # of this project's own -- herdr scopes nothing within a session, so agents working
          # here would otherwise be able to read and drive the other projects' panes.
          # session = "my-project";
          # The project's language toolchain
          packages = [ ];
        };
      }
    );
}

# Build the project with Nix (packages.default)
Using the approach recorded on the epic, add `packages.default` to flake.nix so `nix build` builds the project's main artifact from a clean checkout, offline in the sandbox (dependencies come from the lockfile via the chosen Nix tooling, never the network during the build).

- Generate and commit whatever the Nix tooling needs from the lockfile (e.g. gomod2nix.toml, npmDepsHash, uv2nix workspace), and add the regeneration command to the devshell.
- Add further packages (other binaries, a container image via dockerTools) only if the project already builds them.
- Verify: `nix build` succeeds and the result runs (e.g. `./result/bin/<name> --help`).

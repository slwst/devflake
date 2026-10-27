# Integrating a project's build and tests with the flake

The bootstrap epic (created by `devflake-init` for an existing project) brings the project to this
state:

| Flake output | Purpose |
| --- | --- |
| `devShells.default` | `devflake.lib.mkShell` with the project's toolchain in `packages` |
| `packages.default` | the project's main artifact, built offline from its lockfile |
| `checks.*` | tests and linters, run offline in the Nix sandbox by `nix flake check` |

`nix flake check` is the gate the agent presets run before every merge, so it must be
meaningful (it fails when tests or linters fail) and reasonably fast.

When the project's deliverable already is a flake (NixOS, home-manager or nix-darwin
configurations, an overlay, a flake of packages), most of this page does not apply: see
[The project is already a flake](#the-project-is-already-a-flake).

## Principles

- **Dependencies come from the lockfile, never the network at build time.** Each ecosystem has
  a tool that turns its lockfile into fixed-output Nix derivations; use it, and commit whatever
  it generates (or the hash it needs).
- **Checks reuse the build's dependency setup.** A check is a derivation whose `checkPhase` runs
  the tests or linter against the vendored dependencies, and whose `installPhase` just creates
  `$out`. Build it from `src = ./.;`.
- **Tests that cannot run in the sandbox** (network, external services, credentials) are skipped
  there, behind an environment variable, and documented in AGENTS.md.
- **Pin the toolchain** to the version the project declares, where nixpkgs has it.
- **Nix only sees files git tracks.** `git add` new files before `nix build` / `nix flake check`.

Add any extra flake inputs at the top of flake.nix, following the project's nixpkgs where the
input supports it:

```nix
inputs.gomod2nix.url = "github:nix-community/gomod2nix";
inputs.gomod2nix.inputs.nixpkgs.follows = "nixpkgs";
```

and apply overlays through your own `pkgs`:

```nix
pkgs = import nixpkgs { inherit system; overlays = [ gomod2nix.overlays.default ]; };
```

## Go (gomod2nix)

Adapted from the vaporware flake devflake was extracted from, and verified with `nix build` and
`nix flake check`. `gomod2nix generate` writes `gomod2nix.toml` (module hashes) from
`go.mod`/`go.sum`; rerun it after every dependency change and commit the result, or Nix builds
fail. (Before the devshell has `gomod2nix`: `nix run github:nix-community/gomod2nix -- generate`.)

```nix
let
  pkgs = import nixpkgs { inherit system; overlays = [ gomod2nix.overlays.default ]; };
  app = pkgs.buildGoApplication {
    pname = "my-project";
    version = "0.1";
    pwd = ./.;
    src = ./.;
    modules = ./gomod2nix.toml;
    # subPackages = [ "cmd/my-project" ];  # when the main package is not at the root
    CGO_ENABLED = 0;
  };
  # Vendors the gomod2nix-locked modules into ./vendor so checks build offline in the sandbox
  goCheck =
    name: extraInputs: command:
    pkgs.stdenvNoCC.mkDerivation {
      inherit name;
      src = ./.;
      dontBuild = true;
      doCheck = true;
      goVendorDir = app.vendorEnv;
      CGO_ENABLED = 0;
      nativeBuildInputs = [ app.go app.hooks.goConfigHook pkgs.writableTmpDirAsHomeHook ] ++ extraInputs;
      checkPhase = command;
      installPhase = ''mkdir "$out"'';
    };
in
{
  packages.default = app;
  checks = {
    go-test = goCheck "go-test" [ ] "go test ./...";
    go-lint = goCheck "go-lint" [ pkgs.golangci-lint ] "golangci-lint run";
  };
  devShells.default = devflake.lib.mkShell {
    inherit pkgs;
    name = "my-project";
    packages = [ (pkgs.mkGoEnv { pwd = ./.; }) pkgs.gomod2nix pkgs.golangci-lint ];
  };
}
```

Alternative without generated files: `pkgs.buildGoModule` with `vendorHash` (set it to
`lib.fakeHash`, build, and copy the hash Nix reports); `go test` runs in its `checkPhase` by default.

## Rust (crane)

Use [crane](https://github.com/ipetkov/crane): `craneLib.buildDepsOnly` builds the dependency
layer once from `Cargo.lock`, and `buildPackage`, `cargoClippy`, `cargoNextest`/`cargoTest`,
`cargoFmt` reuse it via `cargoArtifacts`, which maps directly onto `packages.default` and
`checks`. Pin the toolchain with `rust-overlay` or `fenix` if the project has a
`rust-toolchain.toml`.

## Node / TypeScript

- npm: `pkgs.buildNpmPackage` with `npmDepsHash` (or `importNpmLock` to read
  `package-lock.json` without a hash). Checks are `buildNpmPackage` derivations with
  `npmBuildScript = "test"` / `"lint"` and `dontNpmInstall = true`, or a `checkPhase`.
- pnpm: `pkgs.pnpm.fetchDeps` + `pkgs.pnpm.configHook`; yarn: `pkgs.yarnConfigHook` with
  `fetchYarnDeps`.
- Tests that need a browser (Playwright, Cypress) usually cannot download one in the sandbox;
  use `pkgs.playwright-driver.browsers` or skip them in the check.

## Python

- uv projects: [uv2nix](https://github.com/pyproject-nix/uv2nix) builds a virtualenv from
  `uv.lock`; run `pytest` / `ruff check` in checks against that venv.
- Others: `pkgs.python3Packages.buildPythonApplication` with dependencies from nixpkgs, with
  `pytestCheckHook` for tests.

## JVM

- Maven: `pkgs.maven.buildMavenPackage` with `mvnHash`; tests run in its build unless skipped.
- Gradle: `pkgs.gradle` with its `mitmCache` (see the nixpkgs manual, "Gradle") to make
  dependencies fixed-output.

## Anything else

When no ecosystem tool fits, a check can still wrap the project's own test command, as long as
dependencies are fetched by a fixed-output derivation (known hash) rather than during the
check. Record the trade-off in AGENTS.md.

## The project is already a flake

A NixOS, home-manager or nix-darwin configuration, an overlay or a flake of packages already
builds with Nix, so the table above maps onto it loosely:

- **There is no lockfile-to-Nix step.** Dependencies already come from `flake.lock`, so the
  bootstrap toolchain bead has nothing to choose; record that on the epic and close it.
- **`packages.default` may legitimately be absent.** A configuration flake's artifacts are
  `nixosConfigurations.<host>.config.system.build.toplevel` (or
  `homeConfigurations.<name>.activationPackage`, `darwinConfigurations.<host>.system`), not one
  main package. Leave `packages.default` unset rather than pointing it at something arbitrary,
  and close the bootstrap build bead as not applicable. A flake of packages keeps whatever
  `packages` it already has.
- **The meaningful checks** are the formatter in `--check` mode (whichever one the flake
  declares as its `formatter`: alejandra, nixfmt), each configuration's build, and optionally
  [statix](https://github.com/oppiliappan/statix) and
  [deadnix](https://github.com/astro/deadnix):

```nix
checks = {
  fmt = pkgs.runCommand "fmt-check" { nativeBuildInputs = [ pkgs.alejandra ]; } ''
    alejandra --check ${./.} && touch $out
  '';
  # nixfmt instead: nativeBuildInputs = [ pkgs.nixfmt-rfc-style ]; nixfmt --check $(find ${./.} -name '*.nix')
  statix = pkgs.runCommand "statix-check" { nativeBuildInputs = [ pkgs.statix ]; } ''
    statix check ${./.} && touch $out
  '';
  deadnix = pkgs.runCommand "deadnix-check" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
    deadnix --fail ${./.} && touch $out
  '';
  laptop = self.nixosConfigurations.laptop.config.system.build.toplevel;
  server = self.nixosConfigurations.server.config.system.build.toplevel;
};
```

A `toplevel` in `checks` makes `nix flake check` build the whole system closure. That is the
real gate, and it is slow. `nix flake check` already evaluates every
`nixosConfigurations.<host>` (it does not build them), and evaluating the derivation path:

```sh
nix eval .#nixosConfigurations.laptop.config.system.build.toplevel.drvPath
```

catches module and option errors in seconds. For a repo whose agents run the gate often, that is
usually the right trade: leave the toplevels out of `checks`, or evaluate them there without
building them,

```nix
laptop = pkgs.writeText "laptop-drv"
  (builtins.unsafeDiscardStringContext
    self.nixosConfigurations.laptop.config.system.build.toplevel.drvPath);
```

and build the closures in CI or before deploying. `nix flake check` does not know
`homeConfigurations`, so a home-manager profile is only evaluated if `checks` names it the same
way (`self.homeConfigurations.<name>.activationPackage`).

The formatter check and the repo's existing formatting usually disagree on first contact: a repo
that has never run `nix fmt` in CI needs one reformat commit before the check can go in. Give it
its own bead, so the reformat is not mixed into the integration.

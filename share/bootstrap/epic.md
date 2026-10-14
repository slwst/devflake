# devflake bootstrap: build and test this project through the flake
Bring the project's existing build and tests under Nix so the devflake workflow can rely on them: the devshell provides the toolchain, `nix build` builds the project, and `nix flake check` runs the tests and linters offline in the Nix sandbox. `nix flake check` is the gate every agent runs before merging (see the bd-epic and bd-ready presets), so until this epic is done that gate checks nothing. Finish it before scheduling other epics.

Done when, from a clean clone:
- `nix develop` provides the toolchain the project's own docs/scripts expect;
- `nix build` builds the project's main artifact(s) (`packages.default`);
- `nix flake check` runs the test suite and the project's linters/formatters, and passes;
- AGENTS.md and CLAUDE.md document the Build & Test commands and the lockfile rules.

Guide with per-language recipes (Go, Rust, Node, Python, JVM): `$DEVFLAKE_SHARE/docs/integrating.md` (the path is set in the devshell and every herdr pane). Prefer the ecosystem's established Nix tooling over hand-rolled derivations, and keep everything in flake.nix (or files it imports) so it works from a clean checkout. Nix only sees files git tracks: `git add` new files before `nix build` / `nix flake check`.

# Document Build & Test for agents (AGENTS.md, CLAUDE.md)
Add a "Build & Test" section to AGENTS.md and to CLAUDE.md (agents read one or the other) covering:

- that the devshell (`nix develop`, or direnv) provides the toolchain;
- the everyday commands (build, run, test a single package/file) inside the devshell;
- `nix build` and what it produces, and `nix flake check` as the gate before merging;
- the lockfile rule: after changing dependencies, regenerate the Nix lock data (e.g. `gomod2nix`, the npmDepsHash) and commit it, or Nix builds fail;
- tests that are skipped in the sandbox and how to run them locally.

Keep it short and accurate: run every command you document. Leave the devflake-managed block (between the DEVFLAKE markers) alone.

# Run linters and format checks in nix flake check
Add checks for the linters and formatters the project already uses (from its CI, Makefile, package scripts or config files such as .golangci.yml, eslint, ruff, clippy, rustfmt, prettier), run offline in the sandbox like `checks.tests`. Do not introduce new linters or reformat the code base in this bead; if the project uses none, close this bead saying so.

- Pre-existing lint failures: fix them only if few and mechanical; otherwise configure the check to the project's current baseline and open a follow-up bead for the rest.
- Verify: `nix flake check` runs the linters and passes.

# Run the test suite in nix flake check
Add a `checks.tests` derivation (or one per test suite) that runs the project's tests offline in the Nix sandbox, reusing the dependency setup from `packages.default` (the epic's guide shows the pattern per language). `nix flake check` must fail when a test fails.

- Tests that need network, external services, or credentials: run what can run in the sandbox here; gate the rest behind an environment variable so they skip in the check, and say so in the derivation's comment and in AGENTS.md.
- Verify: `nix flake check` runs the tests and passes; break a test temporarily and confirm the check fails.

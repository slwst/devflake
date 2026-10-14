<!-- BEGIN DEVFLAKE (managed by devflake-init; rerun it to update, edit outside this block) -->
## Development environment (devflake)

The devshell comes from the `devflake` flake input. `nix develop` (or direnv) provides the
project's toolchain plus `bd` (beads), `openspec`, `claude`, `herdr` and `herdr-agents`, and gives
the project a workspace in the herdr session (attach with `herdr`).

- Workflow: an OpenSpec change (`openspec/changes/<change>/`) becomes a beads epic with a
  dependency graph of session-sized children (the `openspec-to-epic` skill), which agents work
  through in parallel (`herdr-agents spawn N --preset bd-epic --var epic=<id> --loop`).
- `nix flake check` is the gate before merging: it runs the tests and linters offline in the Nix
  sandbox. `nix build` builds the project.
- Nix only sees files git tracks: `git add` new files before `nix build` or `nix flake check`.
- Agents in `.worktrees/<name>` claim and release beads with `herdr-agents claim|release`,
  deliver work with `herdr-agents merge`, and never commit `.beads/`.
- Beads is published, not private scratch. Bead text and `bd remember` memories share one
  database that `bd dolt push` replicates to the project's remote, often the code remote and
  possibly public; no flag withholds memories from a push, and a push ships history, so editing
  or deleting a row later does not unpublish it. Keep credentials, tokens, customer data and
  private hostnames out of beads — reference where a value lives, never the value.
- Publish beads the first time with `bd dolt push`, which creates `refs/dolt/data` on the remote;
  `bd sync` fails until it exists. Use `bd sync` thereafter: it pulls, checks for conflicts and
  pushes with retry, so it copes with another replica having moved the remote.
- `bd update --notes` **replaces** a bead's notes; use `--append-notes` to add to them.
- The herdr session is shared with every other devflake project open on the host, each in its own
  workspace, and herdr scopes nothing within a session. Panes outside this repository's workspaces
  are not yours: check `worktree.repo_root` in `herdr workspace list` before acting on a pane.
- The herdr tooling belongs to devflake. Project-specific agent presets go in
  `.herdr/prompts/<name>.md` (they shadow built-in presets of the same name), and notes for
  the captain tab in `.herdr/captain.md`.
<!-- END DEVFLAKE -->

# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [sync-concepts](https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md)
> for the one-screen overview and anti-patterns (don't treat JSONL as the
> source of truth; don't `bd import` during normal operation; don't
> reach for third-party Dolt hosting before trying the default).

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Build & Test

devflake is a Nix flake with no compiled code of its own. Its build is Nix evaluating the flake and
building the shell scripts in `nix/`, each of which goes through shellcheck as it builds. Everything
works from a clean checkout, and there is no generated lock data to regenerate beyond `flake.lock`.

| Command | What it does |
| --- | --- |
| `nix flake check` | The gate before merging: builds `packages.init`, `packages.upgrade` and the four `herdr-*` scripts, running shellcheck on each, and checks that the `.nix` files are nixfmt-formatted. |
| `nix build` | Builds `packages.default` (`devflake-init`); check it with `./result/bin/devflake-init --help`. |
| `nix develop` | devflake's own devshell, which is itself a devflake shell (`self.lib.mkShell`), so it gives devflake a workspace in the shared herdr session. |
| `nix fmt` | Formats the `.nix` files with nixfmt (`formatter = nixfmt-tree`). |
| `nix flake show` | Lists the outputs; a fast evaluation-only sanity check. |
| `nix flake update <input>` | Upgrades one pinned input (`herdr`, `claude-code`, ...). |

- **Nix only sees files git tracks**: `git add` new files before `nix build` or `nix flake check`,
  or Nix will not see them. `git add --intent-to-add` is enough.
- `nix flake check` checks the current system only. `--all-systems` also evaluates the darwin and
  aarch64 outputs, which need a builder for those systems to go further than evaluation.
- There is no test suite beyond the checks. Shellcheck catches quoting and syntax, not behaviour,
  so after changing `nix/herdr-agents.sh`, `nix/devflake-init.sh` or `nix/devflake-upgrade.sh` run the command from a devshell
  as well as `nix flake check`.
- `DEVFLAKE_HERDR=0 nix develop` gives the tools without starting a herdr server.
- Three of beady-eye's tests are skipped on darwin, in an overlay in `flake.nix` that explains why.

## Architecture Overview

devflake has two audiences, and nearly every file serves one or the other:

- **Consumer projects** import it as a flake input and call `devflake.lib.mkShell`. They get the
  agent tooling pinned by *devflake's* `flake.lock` rather than by their own nixpkgs.
- **devflake itself** is developed in the same shell (`devShells.default = self.lib.mkShell`).

| Path | Role |
| --- | --- |
| `flake.nix` | `pkgsFor` builds devflake's own package set — the overlays pinning herdr, beady-eye, mardi-gras, openspec and claude-code — and exports `lib.mkShell`, `packages`, `checks` and `templates.default`. |
| `nix/tools.nix` | Everything keyed on the project *name* and its herdr *session*: `herdr-up`, `herdr-down`, `herdr-captain`, `herdr-agents`, and the `shellHook` that manages the herdr server's lifetime. Imported once per `mkShell` call. |
| `nix/herdr-agents.sh` | The agent lifecycle: a worktree, workspace and agent per spawn, the `--loop` supervisor, `merge`, `claim`/`release`, `report`. |
| `nix/devflake-init.sh` | Idempotent project setup: beads, flake, `.envrc`, `.gitignore`, openspec, skills, the AGENTS.md block, the bootstrap epic. |
| `nix/devflake-upgrade.sh` | Moves a project's `devflake` input to a newer ref (the latest tag by default), re-locks it and refreshes the managed files. |
| `nix/project-files.sh` | The devflake-managed project files — skills, the AGENTS.md/CLAUDE.md block, the `.gitignore` lines — as shell functions sourced by init and upgrade. |
| `share/` | Runtime data rather than code: the captain briefing, prompt presets, the bootstrap beads, the installable skills, and the integration guide. Reachable from the shell and every herdr pane as `$DEVFLAKE_SHARE`. |
| `templates/default/` | The `flake.nix` and `.envrc` that `devflake-init` (and `nix flake init -t`) writes into a project. |

Two indirections are worth knowing:

- **`name` threads through everything.** It is the label of the project's herdr workspace, the
  prefix its agents are named with, and the project beady-eye is told about, so `checkName` in
  `flake.nix` enforces `[a-z][a-z0-9_-]{0,31}` up front rather than letting herdr reject it later.
- **`session` is not `name`.** Every devflake project shares the session `defaultSession`
  (`devflake`), one workspace each, because herdr's sidebar is built to roll several projects up;
  a project opts out with `session` in `mkShell` or `DEVFLAKE_HERDR_SESSION`. So anything the
  tooling looks up in the session must be keyed on the repository path, not on a label or an
  agent name — `herdr-up` finds its workspace by `worktree.checkout_path`, `herdr-agents` by
  `herdr worktree list --cwd`, and `herdr-down` closes by `worktree.repo_root`.
- **`share` is a store path**, so briefings and presets are versioned with the flake. The captain
  briefing is templated as it is built: `@project@` in `share/captain.md` becomes the project name.

## Conventions & Patterns

- **Shell code lives in `nix/*.sh`, not in Nix strings.** Anything longer than a few lines is
  `builtins.readFile`-d into `writeShellApplication`, which runs shellcheck at build time and sets
  `errexit`, `nounset` and `pipefail`. The small `text = ''...''` preambles exist only to set the
  variables a script needs (`share`, `template_dir`, `project`, ...).
- **Declare every runtime dependency in `runtimeInputs`.** `writeShellApplication` prepends them to
  `PATH`, so a script must never rely on the user's environment. Platform-specific commands go in
  `lib.optionals stdenv.hostPlatform.isLinux` — see `herdr-up`.
- **Escaping**: inside a Nix indented string a shell variable is `''${VAR}`, while `${...}` is Nix
  interpolation. Prefer interpolating a store path in over computing it in shell.
- **`devflake-init` must stay rerunnable.** Every step checks whether it has already run, and it
  must never overwrite a file the project owns. A project moves to a newer devflake with
  `devflake-upgrade`, which refreshes the managed files through the same `nix/project-files.sh`
  functions as init, so the two never hold separate copies of them.
- **The managed block.** devflake owns the text between the `<!-- BEGIN DEVFLAKE -->` markers in a
  project's AGENTS.md and CLAUDE.md (`share/agents-block.md`); everything outside those markers
  belongs to the project. The bootstrap epic's last bead is what fills in the project's own
  Build & Test section.
- **Keep `share/captain.md` in step with the tooling.** The briefing documents `herdr-agents` and
  `herdr-up`; changing either without updating it leaves the captain running stale commands. The
  README is the source of truth where the two disagree.
- **Run `nix fmt` before committing.** `checks.fmt` fails the gate on an unformatted `.nix` file.
  Its source is filtered to the `.nix` files, so editing docs or shell scripts does not rebuild it.
- **Agents must not commit `.beads/`.** Every worktree shares the root's beads database, and
  `herdr-agents merge` refuses a branch that touches it (exit status 4).

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->

<!-- BEGIN DEVFLAKE (managed by devflake; devflake-upgrade refreshes it, edit outside this block) -->
## Development environment (devflake)

The devshell comes from the `devflake` flake input. `nix develop` (or direnv) provides the
project's toolchain plus `bd` (beads), `openspec`, `claude`, `herdr` and `herdr-agents`, and gives
the project a workspace in the herdr session (attach with `herdr`).

- Workflow: an OpenSpec change (`openspec/changes/<change>/`) becomes a beads epic with a
  dependency graph of session-sized children (the `openspec-to-epic` skill), which agents work
  through in parallel (`herdr-agents spawn N --preset bd-epic --var epic=<id> --loop`).
- devflake moves with `nix run github:slwst/devflake#upgrade [REF]`, not a hand edit of the
  `devflake` input in `flake.nix`: it also refreshes this block and the devflake skills.
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

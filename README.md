# devflake

A Nix flake that gives any project, in any language, an agentic development environment:

- **herdr**: a headless terminal-multiplexer session per project, with tabs for the bead parade
  (`mg`), a captain (`claude` briefed on the agent tooling), and beady-eye (`bdi`);
- **beads** (`bd`): the issue tracker agents claim and close work in;
- **openspec**: specs for changes, which become bead epics;
- **herdr-agents**: spawns coding agents (claude, codex, opencode) into their own git worktrees
  and herdr workspaces, loops them over an epic's ready beads, and fast-forwards their work into
  the parent branch.

The project keeps its own flake for its language toolchain, build and checks; devflake supplies
the agent tooling, pinned by devflake's own lock.

## Workflow

1. **Initialize.** `devflake-init` adds the flake, beads, openspec and the agent configuration.
2. **Bootstrap (existing projects).** Init creates an epic whose beads bring the project's
   toolchain into the devshell, its build into `nix build`, and its tests and linters into
   `nix flake check`, the gate every agent runs before merging. Agents work it like any other
   epic.
3. **Spec → epic → agents.** Shape a change with openspec (`/opsx:propose`), turn it into an epic
   with a dependency graph of session-sized beads (the `openspec-to-epic` skill), and schedule
   agents onto it (`herdr-agents spawn N --preset bd-epic --var epic=<id> --loop`). The captain
   tab is briefed to drive all of this.

## Quick start

From the project's root (new or existing; a directory without git gets `git init`):

```bash
nix run github:slwst/devflake#init
git status                      # review; bd init has already committed its own files
direnv allow                    # or: nix develop
herdr                           # attach to the project's herdr session
```

For an existing project, init prints the bootstrap epic's id. Ask the captain to schedule it, or
run:

```bash
herdr-agents spawn --preset bd-epic --var epic=<id> --loop --rm-on-empty
```

Alternatively `nix flake init -t github:slwst/devflake`
writes just `flake.nix` and `.envrc`; then run `nix develop --command devflake-init`.

### What `devflake-init` does

Each step is skipped when already done, so rerunning it is safe (and refreshes the
devflake-managed skill and AGENTS.md block after a devflake update).

| Step | Result |
| --- | --- |
| `bd init` | `.beads/`, the beads sections of AGENTS.md and CLAUDE.md, Claude/Codex/Cursor hooks and the beads skill. bd commits these itself, so it runs first, on a clean index. |
| flake | `flake.nix` from the template, named after the directory (`--name` to override). An existing flake without devflake is left alone; the snippet to add is printed. |
| `.envrc` | `use flake` |
| `.gitignore` | `/.worktrees/`, `.direnv/`, `/result*` |
| `openspec init` | `openspec/` plus the opsx commands and skills for `--tools` (default `claude,codex,opencode`) |
| skills | `openspec-to-epic` in `.claude/skills`, `.agents/skills` (and `.opencode/skills`) |
| AGENTS.md | a devflake block (also in CLAUDE.md), replaced on every run |
| bootstrap | for a project with files of its own (`--bootstrap`/`--no-bootstrap` to force), the `devflake-bootstrap` epic |

New files are marked intent-to-add in git so Nix can see them; nothing else is staged or committed.

## Using devflake in a flake

```nix
inputs.devflake.url = "github:slwst/devflake";

devShells.default = devflake.lib.mkShell {
  inherit pkgs;              # the project's nixpkgs; provides mkShell
  name = "my-project";       # herdr session and workspace name: [a-z][a-z0-9_-]{0,31}
  packages = [ pkgs.go ];    # the project's toolchain
  # anything else (inputsFrom, env vars, ...) goes to pkgs.mkShell; shellHook runs after devflake's
};
```

`nix flake update devflake` upgrades the tooling. Language recipes for `packages.default` and
`checks` (Go, Rust, Node, Python, JVM) are in [share/docs/integrating.md](share/docs/integrating.md),
also available in the devshell as `$DEVFLAKE_SHARE/docs/integrating.md`.

## Devshell

Entering the devshell puts these on `PATH`: `bd`, `bdi` (beady-eye), `mg` (mardi-gras), `openspec`,
`claude`, `opencode`, `herdr`, `devflake-init`, the commands below, and the project's `packages`.
The devshell's `herdr` must match the server's version, so run herdr commands from the devshell
or a herdr pane rather than with a herdr installed elsewhere.

### herdr session

An interactive `nix develop` (or direnv) starts a headless herdr server for the session named
after the project, with a workspace of the same name at the repo root, whose `parade` tab runs
`mg`, `captain` tab runs `claude`, and `beads` tab runs `bdi`, in that order (each restarted on
entry if it is not running). The server stops when the last devshell exits; its workspaces are
restored on the next start. Panes run your login shell with the devshell environment.

| Command | Description |
| --- | --- |
| `herdr` | Attach to the project session (`HERDR_SESSION` is set by the devshell). |
| `herdr-up [root] [pid]` | Start the server if needed and ensure the project workspace and its `parade`, `captain`, and `beads` tabs. Run automatically on entry. |
| `herdr-captain [--new] root` | Run `claude` with the captain briefing (devflake's, then the project's `.herdr/captain.md`), resuming the root's last conversation (`--new`: start a new one). The captain tab runs it. |
| `herdr-down [pid]` | Stop the server (with a pid: only once no other devshell holds it). Run automatically on exit. |

- direnv has no exit hook, so a server started through direnv runs until `herdr-down`.
- `nix develop --command ...` does not start a server, and shells inside herdr panes leave it alone.
- Stopping the server stops every agent in it.

| Variable | Effect |
| --- | --- |
| `DEVFLAKE_HERDR=0` | Do not start or stop the herdr server. |
| `DEVFLAKE_HERDR_SHELL` | Shell for herdr panes (default: your login shell). |
| `DEVFLAKE_CAPTAIN=0` | Leave out the captain tab. |
| `DEVFLAKE_CAPTAIN_NEW=1` | Start a new captain conversation instead of resuming, when entry (re)starts `claude` in the tab. |
| `DEVFLAKE_PROJECT`, `DEVFLAKE_SHARE` | Set by the devshell: the project name, and the store path of [share/](share/). |

### herdr-agents

Each agent gets a git worktree at `.worktrees/<name>` (gitignored) on a new branch
`agents/<name>`, a herdr workspace, and an agent started in its pane with `BEADS_ACTOR=<name>`,
so its claims and closes are recorded as that agent rather than your git user.

| Command | Description |
| --- | --- |
| `herdr-agents spawn [N] [options] [-- AGENT_ARGS...]` | Spawn N agents (default 1), optionally with an initial prompt. |
| `herdr-agents list` | Show agent worktrees with agent kind, status, branch, and workspace. |
| `herdr-agents rm (NAME... \| --all) [--force] [--delete-branch]` | Remove worktrees and close their workspaces (stopping the agents), first releasing the beads each agent left in progress. Branches are kept unless `--delete-branch` and merged. |
| `herdr-agents merge` | Run by an agent in its worktree: fast-forward the parent branch to the agent branch. |
| `herdr-agents claim ID` / `release ID` | Run by an agent in its pane: claim a bead as that agent and tie it to the pane for beady-eye, or clear that tie. A bead another agent holds is refused. |
| `herdr-agents report (next \| wait \| empty)` | Run by an agent in its worktree: tell its `--loop` supervisor the cycle is done (`next`), nothing is ready until beads in progress finish (`wait`), or there is no work left (`empty`). |
| `herdr-agents presets` | List prompt presets: the project's `.herdr/prompts/` and devflake's built-ins. |

`spawn` options:

| Option | Default | Description |
| --- | --- | --- |
| `-k, --kind KIND` | `claude` | Agent kind for `herdr agent start` (`codex`, `opencode`, ...). |
| `-n, --name PREFIX` | `agent` | Agents are named `PREFIX-1`, `PREFIX-2`, ... (next free numbers). |
| `--parent BRANCH` | root's branch | Branch the agents merge into, recorded as the agent branch's upstream. |
| `-b, --base REF` | parent | Commit to branch from. |
| `-p, --preset NAME` | | Prompt from `.herdr/prompts/NAME.md`, else the built-in preset `NAME`. |
| `--prompt TEXT` / `--prompt-file PATH` | | Inline or ad hoc prompt. Without any prompt option agents start idle. |
| `--var KEY=VALUE` | | Fill `{{KEY}}` in the prompt; repeatable. |
| `--loop` | | Repeat the prompt until the agent reports `empty`. Needs a prompt. |
| `--rm-on-empty` | | With `--loop`: remove the agent once its loop ends on `report empty`. |
| `--timeout MS` | `120000` | How long to wait for each agent to become ready. |

Prompts may use `{{name}}`, `{{branch}}`, `{{parent_branch}}`, and `{{repo_root}}`, filled in per
agent, plus any `{{KEY}}` passed with `--var`. `spawn` refuses to start if a placeholder is left
unfilled. A preset's first line is its description in `herdr-agents presets`.

**Merging.** `herdr-agents merge` is fast-forward only and serialized across agents. If the parent
branch is checked out (e.g. in the repo root) it is merged there, updating that checkout, and
refuses to overwrite uncommitted edits; otherwise the branch is moved directly. Exit status 3
means another agent merged first: `git rebase <parent>`, re-test, retry. Exit status 4 means the
branch changes `.beads/`, which agents must not commit: every worktree uses the root's beads
database, and `.beads/issues.jsonl` is a passive export written in the repo root.

**beady-eye.** `bdi` joins a bead to an agent's pane through the bead's `agent_pane` metadata,
falling back to the pane's herdr display agent. `herdr-agents claim` sets both (and claims the
bead); `release` clears both, and each tells a running `bdi` to re-read at once.

**Looping.** With `--loop`, a supervisor in a `loop` tab of the agent's workspace sends the prompt.
On `report next` it sends `/clear` and the prompt again, so every cycle starts with a fresh
context. On `report wait` it polls `bd` every 30 seconds and starts the next cycle once a bead
that was in progress leaves `in_progress`, or after 15 minutes. `report empty` runs
`bd epic close-eligible` and ends the loop (and, with `--rm-on-empty`, removes the agent; rm's
output goes to `.git/herdr-agents/rm-on-empty.log`). A turn that ends without a report raises a
herdr notification. Supervisors do not survive a herdr server restart.

### Presets

- `bd-ready`: rebase onto the parent branch, claim a ready bead, implement it, run
  `nix flake check`, commit, `herdr-agents merge`, `bd close`, then `herdr-agents report next`.
  When nothing is ready it reports `wait` if open beads are blocked on beads in progress, else
  `empty`.
- `bd-epic`: the same, limited to ready children of one epic. Needs `--var epic=<id>`.

A project adds or overrides presets with `.herdr/prompts/<name>.md`, and adds to the captain's
briefing with `.herdr/captain.md`.

## Layout

| Path | Contents |
| --- | --- |
| `flake.nix` | the pinned tool set, `lib.mkShell`, `packages.init`, `templates.default` |
| `nix/tools.nix` | per-project scripts: `herdr-up`, `herdr-down`, `herdr-captain`, `herdr-agents`, and the shell hook |
| `nix/herdr-agents.sh` | `herdr-agents` |
| `nix/devflake-init.sh` | `devflake-init` |
| `share/captain.md` | the captain briefing (`@project@` is the project name) |
| `share/prompts/` | built-in presets |
| `share/bootstrap/` | the bootstrap epic and its beads (`# title`, then description) |
| `share/skills/` | skills `devflake-init` installs into projects |
| `share/docs/integrating.md` | language recipes for builds and checks |
| `templates/default/` | `flake.nix` and `.envrc` for new projects |

`nix flake check` builds every script (each runs through shellcheck) and checks that the `.nix`
files are nixfmt-formatted (`nix fmt` formats them). Keep `share/captain.md` in step with changes
to `herdr-agents` and `herdr-up`.

## License

MIT — see [LICENSE](LICENSE).

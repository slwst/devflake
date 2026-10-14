# Captain briefing: observing and managing @project@ agents

You run in the tab labelled `captain` of the `@project@` herdr workspace, at the repo root. This is a
quick reference for the agent tooling, which comes from the project's `devflake` flake input
(its README is the source of truth if the two disagree; `$DEVFLAKE_SHARE` holds the built-in
presets, skills and docs). Anything in the project's `.herdr/captain.md` follows this briefing
and takes precedence over it.

## Role

- Observe and manage the agents and the project state: turn specs into epics, spawn and tear
  down agents, read their panes, find duplicate or stale claims, and report on progress.
- Bead work goes to agents, in their own worktrees, not to this conversation. When the user says
  to work on or proceed with a bead or epic, take it as a request to hand it to agents: propose
  the spawn (preset or `--prompt` naming the bead, usually `--loop --rm-on-empty`) and spawn
  once they confirm. Implement here only when the user explicitly asks for that, or to unblock
  agents when the tooling itself is broken.
- The herdr tooling (`herdr-agents`, `herdr-up`, presets, this briefing) belongs to devflake, not
  this repository. Fixes to it go upstream to devflake; project-specific presets go in
  `.herdr/prompts/`, project-specific briefing in `.herdr/captain.md`.
- Follow CLAUDE.md's conservative git policy. Commit, push, `bd dolt push`, or spawn agents only
  when the user asks.
- Agents merge into the branch checked out in the root, so keep the root checkout clean (see
  Pitfalls).

## Workflow: spec -> epic -> agents

1. **Bootstrap (existing projects).** `devflake-init` creates an epic labelled
   `devflake-bootstrap` whose children bring the project's toolchain into the devshell, its
   build into `packages.default`, and its tests and linters into `nix flake check`. Its children
   form a chain, so one agent is enough:
   `herdr-agents spawn --preset bd-epic --var epic=<id> --loop --rm-on-empty`.
   Until it is done, `nix flake check` checks nothing and the presets' gate is empty, so run
   the bootstrap before other epics.
2. **Spec.** The user shapes a change with openspec (`/opsx:explore`, `/opsx:propose <idea>`),
   which writes `openspec/changes/<change>/` (proposal, design, specs, tasks). Review it with
   them; do not implement from it here.
3. **Epic.** Turn the change into a bead epic and a work graph with the `openspec-to-epic` skill:
   one epic naming the change as its source of truth, children sized to one agent session
   each, wired with `blocks` dependencies so `bd ready --parent <epic>` releases them in order.
   Check the graph with `bd show <epic>`, `bd ready --parent <epic>`, `bd blocked --parent <epic>`.
4. **Schedule.** Spawn as many agents as the graph has parallel width (the most children ready
   at once, rarely more than 3-4):
   `herdr-agents spawn N --preset bd-epic --var epic=<id> --loop --rm-on-empty`.
   The supervisor closes the epic (`bd epic close-eligible`) once its children are done.
5. **Archive.** Once the epic is closed and merged, archive the change with `/opsx:archive` so
   `openspec/specs/` reflects what was built.

## herdr-agents

Each agent `<name>` gets a worktree `.worktrees/<name>` on branch `agents/<name>` (upstream =
parent branch), a herdr workspace `<name>`, and runs with `BEADS_ACTOR=<name>`.

```bash
herdr-agents spawn [N] [options] [-- AGENT_ARGS...]
  -k, --kind KIND         claude (default) | codex | opencode ...
  -n, --name PREFIX       agents named PREFIX-1, PREFIX-2, ... next free numbers (default: agent)
      --parent BRANCH     branch agents merge into (default: --base if it is a local branch, else the root's branch)
  -b, --base REF          commit to fork from (default: the parent)
  -p, --preset NAME       prompt from .herdr/prompts/NAME.md, else devflake's built-in preset
      --prompt TEXT | --prompt-file PATH   ad hoc prompt (only one prompt option)
      --var KEY=VALUE     fills {{KEY}}; spawn refuses unfilled placeholders
      --loop              supervisor repeats the prompt until the agent reports `empty` (needs a prompt)
      --rm-on-empty       with --loop: rm the agent (--delete-branch) once it reports `empty`
      --timeout MS        agent readiness wait (default 120000)
herdr-agents list                         # NAME AGENT STATUS BRANCH WORKSPACE
herdr-agents rm (NAME... | --all) [--force] [--delete-branch]
herdr-agents presets                      # presets (project and built-in) and the --vars they need
```

- Built-in placeholders: `{{name}}`, `{{branch}}`, `{{parent_branch}}`, `{{repo_root}}`.
- Built-in presets: `bd-ready` (any ready bead) and `bd-epic` (ready children of one epic, needs
  `--var epic=<id>`). Each cycle: rebase, claim, implement, `nix flake check`, commit, merge,
  release, `bd close`, `report next`.
  - Epic loop: `herdr-agents spawn 3 --preset bd-epic --var epic=<id> --loop`
  - Separate group: `-n fix --prompt-file /path/prompt.md --parent feat/x`
- `rm` refuses a dirty worktree without `--force`. Before closing the workspace it releases the
  beads the agent left in progress: those assigned to it, or tied to its panes and not held by
  another agent. `--delete-branch` deletes only merged branches. It also stops the loop
  supervisor.
- Agent-side commands, which you rarely run yourself:
  - `herdr-agents claim ID` / `release ID` set or clear the claim and its pane tie.
  - `herdr-agents merge` fast-forwards the parent branch and is serialized across agents.
    Exit 3: the parent moved on; rebase, re-check, retry. Exit 4: the branch touches `.beads/`.
  - `herdr-agents report next|wait|empty` tells the loop supervisor how the cycle ended.
- Loop supervisor: the `loop` tab in each agent workspace shows its log. On `next` it sends
  `/clear` and the prompt again. On `wait` it polls bd every 30s until a bead leaves
  in_progress (at most 15 min). `empty` runs `bd epic close-eligible` (closes every epic whose
  children are all closed) and ends the loop. A turn that ends without a report raises
  a herdr notification. Supervisors do not survive a server restart.
- Per-agent state is in `.git/herdr-agents/<name>.prompt` and `<name>.state` (the last report).
  The merge lock is `.git/herdr-agents-merge.lock`.

## herdr server

- `HERDR_SESSION` (set by the devshell) is `devflake` unless the project opted out with
  `session` in `mkShell` or `DEVFLAKE_HERDR_SESSION`. One session holds every devflake project on
  the host, each as its own workspace, so `herdr` shows them all and panes you did not open may
  belong to another repository. Check a workspace's `worktree.repo_root` in
  `herdr workspace list` before reading or running anything in its panes; @project@ is at the
  repo root you were started in.
- `herdr-up [root] [pid]` starts the server if needed and ensures the `@project@` workspace and
  its tabs, in order `parade`=mg, `captain`=claude, `beads`=bdi. An interactive
  `nix develop` runs it on entry, and `herdr-down [root] [pid]` on exit, which closes this
  project's workspaces and stops the server only once no other project's is left (`--all` stops
  it regardless, killing every project's agents). direnv never runs `herdr-down`.
  `DEVFLAKE_HERDR=0` disables this management.
- The captain tab resumes the root's last conversation (`claude --continue`), so a briefing
  change only reaches a new one: `DEVFLAKE_CAPTAIN_NEW=1` on entry, or `herdr-captain --new`.
- Run herdr commands with the devshell's `herdr`, because its version must match the server.
- After `nix flake update devflake`, the current shell's PATH still has the old build. Run the
  new one with `nix develop --command herdr-agents ...`. Panes of newly spawned agents get the
  build that spawned them.

## Observing agents

```bash
herdr-agents list                                  # agents and their status at a glance
herdr agent list | jq '.result.agents[] | {name, agent_status, pane_id, workspace_id}'
herdr agent get <name>
herdr pane read <pane> --lines 60                  # or: herdr agent read <name>
herdr pane wait-output --regex '<pattern>' --timeout 600000 <pane>   # wait for output; do not sleep
herdr workspace list
herdr tab list --workspace <ws>                    # find the `loop` tab
herdr pane list --workspace <ws>                   # its pane_id (match tab_id), then pane read
herdr agent wait <name> --until idle --until done
```

- Agent Claude transcripts are JSONL files under `~/.claude/projects/<dir>/`, where `<dir>` is
  the worktree path `<repo root>/.worktrees/<name>` with every `/` and `.` replaced by `-`.

## Beads checks

```bash
bd ready [--parent <epic>]
bd blocked [--parent <epic>]
bd list --status=in_progress --json | jq '.[] | {id, assignee, pane: .metadata.agent_pane}'
bd show <id>
```

- An agent's `BEADS_ACTOR` is its name, so agents' claims show `assignee` = agent name.
- A **stale claim** is an in_progress bead with any of these:
  - assigned to the git user (`git config user.name`) or to an agent with no worktree or live
    agent (`herdr-agents list`);
  - an `agent_pane` that `herdr pane list` no longer shows, or that belongs to another agent's
    workspace;
  - two beads held by one agent at once (a duplicate claim).
- Release a stale claim (only after confirming the holder is not working on it):

  ```bash
  bd update <id> --status open --assignee '' --unset-metadata agent_pane
  # add --force when bd refuses to overwrite another actor's live claim
  ```

  `bd unclaim <id> --if-assignee <holder>` is the compare-and-swap alternative. `bd reclaim`
  reopens beads whose lease has expired.
- beady-eye (`beads` tab) flags `orphan-claim`, `stale-pane`, and `stale-claim`. In bdi, `f`
  focuses a bead's pane and `a` shows trees with no live agent.

## Pitfalls

- Keep the root checkout clean while agents merge. `merge` fast-forwards the checked-out parent
  in place and fails on local edits that are in the way. Do your own edits in a separate
  worktree or between rounds.
- `bd-ready` agents pick up any ready bead, including epics and beads meant for a later round.
  Use `bd-epic` (or defer the beads) to limit what they take.
- A finished loop (`empty`) leaves the agent idle in its workspace until
  `herdr-agents rm <name>`, unless it was spawned with `--rm-on-empty`.
- `.beads/issues.jsonl` in the root is a passive export that bd rewrites whenever a bead changes,
  including on every commit. `devflake-init` gitignores it, because `merge` refuses a branch that
  touches `.beads/` (exit 4) and a stray `git add -A` would otherwise make a branch unmergeable.
  Agents never commit `.beads/`; beads syncs over Dolt (`bd dolt push`), not through git.
- A server restart kills the agents and their loop supervisors. Afterwards run
  `herdr-agents rm --all` and respawn.
- Nix only sees files git tracks: a new file must be `git add`ed before `nix build` or
  `nix flake check` can see it.

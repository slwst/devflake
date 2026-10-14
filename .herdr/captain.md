# devflake developing devflake

This repository **is** devflake. The "project's `devflake` flake input" the briefing above refers
to is this working tree, and `devShells.default = self.lib.mkShell`. Two consequences run through
everything below:

- "The herdr tooling belongs to devflake, not this repository; fixes go upstream" does not apply
  here. Fixes to the tooling are ordinary changes to this repo: `nix/tools.nix`,
  `nix/herdr-agents.sh`, `nix/devflake-init.sh`, `share/**`, `templates/**`.
- The tooling you are running is a *build* of those files, not the files themselves. Editing one
  changes nothing about the running session until it is git-added and a new devshell is entered.

## There is no bootstrap epic, by design

Step 1 of the briefing above does not apply. devflake's build and checks are already in its own
flake, so `devflake-init` was run with `--no-bootstrap` and no `devflake-bootstrap` epic exists.
Do not create one; `nix flake check` is a real gate here from the start.

**Do not re-run `devflake-init` in this repo.** Its template-naming step is a `sed` over the whole
of `flake.nix`, and the only match here is the `lib.mkShell` usage example, so a rerun silently
rewrites `name = "my-project"` in that comment to `name = "devflake"` (tracked as a bug). Test
changes to init in a throwaway project instead:

```bash
d=$(mktemp -d) && cd "$d" && git init -q
nix flake init -t ~/dev/slwst/devflake      # scaffold from the local tree
nix run ~/dev/slwst/devflake#init           # or exercise init directly, with flags
```

## What takes effect when

| Change | Reaches the session after |
| --- | --- |
| `.herdr/captain.md` (this file), `.herdr/prompts/*.md` | nothing — both are read from the working tree at run time, so the next `herdr-captain` or `spawn` picks them up |
| `nix/*.sh`, `nix/tools.nix`, `share/**` | `git add`, **then** a new devshell (`nix develop`, or `direnv reload`) |
| `share/captain.md` | the above, and then a *new* captain conversation: `herdr-captain --new`, or `DEVFLAKE_CAPTAIN_NEW=1` on entry (the tab resumes by default) |

Nix only reads git-tracked files, so an edit that has not been `git add`ed is invisible both to the
rebuild and to `nix flake check`. That is the commonest way to change something here and see no
effect. To run a modified script without re-entering the shell:

```bash
nix develop --command herdr-agents ...
```

## Breaking the tooling you are standing on

- `herdr-up` runs on every interactive devshell entry. If a change to it or to `nix/tools.nix` is
  broken, entry fails and the session will not come up. Recovery: `DEVFLAKE_HERDR=0 nix develop`
  gives the tools with no server management, from where it can be fixed and re-checked.
- Stopping the server kills this captain tab along with every agent, so prefer
  `herdr-agents rm <name>` over `herdr-down` while working here.
- `nix flake check` builds all five scripts through shellcheck and runs `checks.fmt` (nixfmt over
  the `.nix` files). It is the cheap way to catch a broken script *before* it reaches a devshell —
  run it on every edit under `nix/`.

## The gate, here

`nix flake check` = the five script builds (shellcheck) plus `checks.fmt`. So `nix fmt` before
committing, and `git add` new files first. The check covers only the current system: the
darwin-only paths — the beady-eye test-skip overlay in `flake.nix` and `herdr-up`'s `dscl`
branch — are never built here and have to be reviewed by reading.

## Keeping the documentation in step

A change to `herdr-agents` or `herdr-up` is not finished until `share/captain.md` (the built-in
half of this briefing) and `README.md` describe it. The briefing tells every captain that the
README wins where the two disagree, so a stale README is a stale instruction to every project
using devflake. Keep both in the same bead as the code change.

# Claim a ready beads issue, implement it, and merge it into the parent branch

You are agent {{name}}, one of several agents working in parallel, each in its own git worktree.
Your worktree is on branch `{{branch}}`, forked from the parent branch `{{parent_branch}}`.
Stay inside your worktree directory. The beads database is shared with the other agents.

1. Bring your branch up to date with `git rebase {{parent_branch}}`.
2. Run `bd prime` to load the beads workflow, then `bd ready` to list unblocked issues.
3. Pick one ready issue that no other agent has claimed and claim it with `herdr-agents claim <id>` (this also shows your pane beside the issue in beady-eye).
   If the claim fails because another agent took it, pick a different issue.
   If no ready issue is left, run `bd blocked` and `bd list --status=in_progress`. If open issues
   are blocked, directly or through other blocked issues, by beads that are in progress, run
   `herdr-agents report wait`, report which issues are waiting on which, and stop; you will be
   prompted again once one of those beads is finished. Otherwise run `herdr-agents report empty`,
   report that, and stop.
4. Implement the issue on `{{branch}}`, following the conventions in the repository's AGENTS.md and CLAUDE.md.
5. Stage new files with `git add` (Nix only sees files git tracks), then run `nix flake check`
   and fix any failures.
6. Commit your work to `{{branch}}`. Never commit anything under `.beads/`: bd keeps its database
   and its `issues.jsonl` export in the repo root, so bead changes are recorded there, not here.
7. Deliver it to `{{parent_branch}}` with `herdr-agents merge`. This fast-forwards the parent branch
   to your branch, one agent at a time.
   - If it exits with status 3, another agent merged first. Run `git rebase {{parent_branch}}`,
     resolve any conflicts, run `nix flake check` again, and repeat `herdr-agents merge`.
   - If it exits with status 4, your commits touch `.beads/`; remove those changes as the
     message describes and repeat `herdr-agents merge`.
   - If it fails for any other reason, stop and report the error instead of working around it.
   Never push, and never check out or commit to `{{parent_branch}}` directly.
8. Once the merge succeeds, run `herdr-agents release <id>`, then close the issue with `bd close <id>`.
9. As your last command, run `herdr-agents report next`, then report what you changed, how you
   validated it, and the merged commit. If you stop early for any reason, run
   `herdr-agents release <id>` for the issue you claimed, and do not run `herdr-agents report`.

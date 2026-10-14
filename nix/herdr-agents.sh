# herdr-agents: spawn coding agents into their own git worktree + herdr workspace.
# Packaged by devflake's nix/tools.nix via writeShellApplication (strict mode, shellcheck, runtime PATH),
# which sets HERDR_SESSION, project and builtin_presets before this file.

usage() {
  cat <<'EOF'
Usage:
  herdr-agents spawn [N] [options] [-- AGENT_ARGS...]
  herdr-agents list
  herdr-agents rm (NAME... | --all) [--force] [--delete-branch]
  herdr-agents merge
  herdr-agents report (next | wait | empty)
  herdr-agents claim ID
  herdr-agents release ID
  herdr-agents presets

spawn creates N agents (default 1). Each gets a worktree at .worktrees/<name> on a new
branch agents/<name>, a herdr workspace grouped under the repo, and an agent in its pane.
The agent branch tracks a parent branch (its git upstream) that `merge` delivers work to.

spawn options:
  -k, --kind KIND          agent kind passed to `herdr agent start` (default: claude)
  -n, --name PREFIX        agent name prefix; agents are PREFIX-1, PREFIX-2, ... (default: the
                           project name, since agent names are unique across the herdr session)
  -b, --base REF           start branches from REF (default: the parent branch, else HEAD)
      --parent BRANCH      branch agents merge into (default: --base if it is a local branch,
                           else the branch checked out in the repo root)
  -p, --preset NAME        initial prompt from .herdr/prompts/NAME.md, else devflake's built-in
                           preset NAME (see: herdr-agents presets)
      --prompt TEXT        initial prompt text
      --prompt-file PATH   initial prompt read from PATH
      --var KEY=VALUE      fill {{KEY}} in the prompt (repeatable), e.g. --var epic=<id>
      --loop               repeat the prompt: when the agent runs `herdr-agents report next`, a
                           supervisor (tab "loop" in the agent's workspace) sends /clear and the
                           prompt again; `report wait` does the same once an in-progress bead
                           is closed or released (or after a while); `report empty` closes
                           the epics whose children are all done (bd epic close-eligible)
                           and ends the loop. Requires a prompt.
      --rm-on-empty        with --loop: once the loop ends on `report empty`, remove the agent
                           (herdr-agents rm --delete-branch, so its branch goes only if merged).
                           A loop that ends any other way leaves the agent in place.
      --timeout MS         how long to wait for each agent to become ready (default: 120000)
  Without a prompt option the agents start idle. Arguments after -- go to the agent CLI.
  Prompts may use {{name}}, {{branch}}, {{parent_branch}} and {{repo_root}}, plus any {{KEY}}
  given with --var. Spawning fails if a placeholder is left unfilled.

rm options:
  --all                    remove every agent worktree under .worktrees/
  --force                  remove worktrees with uncommitted changes
  --delete-branch          also delete agents/<name> (only if merged; unmerged branches are kept)
  Before closing an agent's workspace, rm releases the beads it leaves in progress: those
  assigned to it, or tied to one of its panes and not assigned to another agent.

merge (run inside an agent worktree) fast-forwards the parent branch to the agent branch.
Merges are serialized across agents. If the parent branch is checked out (e.g. in the repo
root), it is merged there, updating that checkout; otherwise the branch ref is moved directly.
Exit status 3 means the parent has moved on: rebase onto it, re-test, and run merge again.
Exit status 4 means the agent branch changes .beads/; bd exports to the repo root, so agent
commits must not include it (the dirty export in the root never blocks a merge otherwise).

claim and release (run by an agent in its herdr pane) claim a bead and tie it to the pane for
beady-eye (bdi): the bead's agent_pane metadata names the pane, the pane's display agent names
the bead. release clears both; run it whenever you stop working on a bead, before `bd close`.

report (run inside an agent worktree) tells a --loop supervisor how the cycle ended: `next` to
clear the agent's context and send the prompt again, `wait` when nothing is ready but open work
is blocked on beads still in progress (the prompt is sent again once one of them leaves
in_progress, or after 15 minutes), `empty` when there is no work left.
EOF
}

# Placeholders filled by render_prompt itself; anything else comes from --var
builtin_vars=(name branch parent_branch repo_root)
declare -A prompt_vars=()

die() {
  echo "herdr-agents: $*" >&2
  exit 1
}

# Main checkout root, even when run from inside an agent worktree
root="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
  die "not inside a git repository"
root="$(dirname "$root")"
worktrees="$root/.worktrees"
# This herdr-agents build. Agent panes get it first on PATH: the server's PATH comes from whichever
# devshell started it, which may predate this version.
self_bin="$(dirname "$(readlink -f "$0")")"
# Per-agent loop state (prompt, last report) lives in the shared git dir, outside worktrees
state_dir="$root/.git/herdr-agents"
# Project presets; a project preset shadows the built-in preset of the same name
presets="$root/.herdr/prompts"
# Agent names are unique across the herdr session, which every devflake project shares by default,
# so they carry the project: devflake-1, vaporware-1, ... (-n overrides). 27 characters leaves room
# for the -<index> suffix.
default_prefix="$(printf '%.27s' "$project" | sed -E 's/[_-]+$//')"

# Error code from a herdr CLI JSON error (printed on stderr), or empty
herdr_error_code() {
  jq -r '.error.code // empty' 2>/dev/null <<<"$1" || true
}

cmd_spawn() {
  local count=1 kind=claude prefix="$default_prefix" base="" parent="" timeout=120000
  local prompt="" prompt_src="" loop=0 rm_on_empty=0
  local -a agent_args=()

  if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
    count="$1"
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -k | --kind) kind="${2:?--kind needs a value}"; shift 2 ;;
    -n | --name) prefix="${2:?--name needs a value}"; shift 2 ;;
    -b | --base) base="${2:?--base needs a value}"; shift 2 ;;
    --parent) parent="${2:?--parent needs a value}"; shift 2 ;;
    -p | --preset)
      [[ -z "$prompt_src" ]] || die "use only one of --preset, --prompt, --prompt-file"
      prompt_src="$(preset_file "${2:?--preset needs a value}")" || die "no preset '$2' (see: herdr-agents presets)"
      prompt="$(<"$prompt_src")"
      shift 2
      ;;
    --prompt)
      [[ -z "$prompt_src" ]] || die "use only one of --preset, --prompt, --prompt-file"
      prompt="${2:?--prompt needs a value}"
      prompt_src="inline"
      shift 2
      ;;
    --prompt-file)
      [[ -z "$prompt_src" ]] || die "use only one of --preset, --prompt, --prompt-file"
      prompt_src="${2:?--prompt-file needs a value}"
      [[ -f "$prompt_src" ]] || die "no such file: $prompt_src"
      prompt="$(<"$prompt_src")"
      shift 2
      ;;
    --var)
      [[ "${2:-}" =~ ^([a-z][a-z0-9_]*)=(.*)$ ]] || die "--var needs KEY=VALUE (KEY: lowercase, digits, _)"
      [[ " ${builtin_vars[*]} " != *" ${BASH_REMATCH[1]} "* ]] || die "--var cannot set built-in {{${BASH_REMATCH[1]}}}"
      prompt_vars["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      shift 2
      ;;
    --loop) loop=1; shift ;;
    --rm-on-empty) rm_on_empty=1; shift ;;
    --timeout) timeout="${2:?--timeout needs a value}"; shift 2 ;;
    --) shift; agent_args=("$@"); break ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown spawn option: $1" ;;
    esac
  done

  ((count >= 1)) || die "N must be at least 1"
  # herdr agent names: [a-z][a-z0-9_-]{0,31}, leaving room for the -<index> suffix
  [[ "$prefix" =~ ^[a-z][a-z0-9_-]{0,27}$ ]] || die "invalid name prefix '$prefix'"
  [[ -z "$prompt_src" || -n "${prompt//[[:space:]]/}" ]] || die "prompt from $prompt_src is empty"
  ((!loop)) || [[ -n "$prompt_src" ]] || die "--loop needs a prompt (--preset, --prompt, or --prompt-file)"
  ((!rm_on_empty || loop)) || die "--rm-on-empty needs --loop"
  if [[ -z "$parent" ]]; then
    if [[ -n "$base" ]] && git -C "$root" show-ref --verify --quiet "refs/heads/$base"; then
      parent="$base"
    else
      parent="$(git -C "$root" symbolic-ref --quiet --short HEAD || true)"
    fi
  fi
  if [[ -n "$parent" ]]; then
    git -C "$root" show-ref --verify --quiet "refs/heads/$parent" || die "no local branch '$parent'"
  elif [[ "$prompt" == *"{{parent_branch}}"* ]]; then
    die "repo root is detached; pass --parent BRANCH (or --base BRANCH) for {{parent_branch}}"
  fi
  local missing
  missing="$(render_prompt "$prompt" "$prefix" "$parent" | grep -oE '\{\{[a-z][a-z0-9_]*\}\}' | sort -u | tr '\n' ' ' || true)"
  [[ -z "$missing" ]] || die "prompt has unfilled placeholders: $missing(pass them with --var KEY=VALUE)"
  base="${base:-${parent:-HEAD}}"
  git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "unknown base ref '$base'"

  # Exit 2 is a tab that did not start, which does not stop us needing the session
  herdr-up "$root" >/dev/null || (($? == 2))

  local live_names
  live_names="$(herdr agent list | jq -r '.result.agents[]?.name // empty')"

  # Pick the next free names: no existing worktree dir, branch, or live agent with that name
  local -a names=()
  local i=1 name
  while ((${#names[@]} < count)); do
    name="$prefix-$i"
    if [[ ! -e "$worktrees/$name" ]] &&
      ! git -C "$root" show-ref --verify --quiet "refs/heads/agents/$name" &&
      ! grep -qxF "$name" <<<"$live_names"; then
      names+=("$name")
    fi
    i=$((i + 1))
  done

  mkdir -p "$worktrees" "$state_dir"
  local -a pids=()
  local created pane workspace
  for name in "${names[@]}"; do
    created="$(herdr worktree create --cwd "$root" --branch "agents/$name" --base "$base" \
      --path "$worktrees/$name" --label "$name" --no-focus)" ||
      die "failed to create worktree for $name"
    pane="$(jq -r '.result.root_pane.pane_id' <<<"$created")"
    workspace="$(jq -r '.result.workspace.workspace_id' <<<"$created")"
    # Immediately, because `herdr worktree create` has already started the pane's shell: its first
    # prompt may have run the direnv hook and unloaded the inherited devshell. Approving now means
    # the hook loads the worktree's own devshell on the next prompt, which `start_agent`'s pane
    # command provides, before `herdr agent start` launches the agent in that shell.
    approve_worktree_envrc "$name"
    # The upstream records which branch `herdr-agents merge` delivers to
    if [[ -n "$parent" ]]; then
      git -C "$root" branch --quiet --set-upstream-to="$parent" "agents/$name"
    fi
    echo "$name: worktree .worktrees/$name (branch agents/$name${parent:+ -> $parent}), pane $pane"

    # Start agents concurrently; each job reports its own outcome
    rm -f "$state_dir/$name".*
    # Read by the supervisor when the loop ends on `report empty`
    if ((rm_on_empty)); then
      : >"$state_dir/$name.rm-on-empty"
    fi
    start_agent "$name" "$pane" "$workspace" "$kind" "$timeout" \
      "$(render_prompt "$prompt" "$name" "$parent")" "$loop" "${agent_args[@]}" &
    pids+=($!)
  done

  local failed=0 pid
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=$((failed + 1))
  done
  if ((failed > 0)); then
    die "$failed of ${#names[@]} agents did not start cleanly (see above)"
  fi
  echo "spawned ${#names[@]} $kind agent(s)${prompt_src:+ with prompt from $prompt_src}$( ((loop)) && echo ", looping")$( ((rm_on_empty)) && echo ", removed once out of work");" \
    "attach with: herdr"
}

# render_prompt PROMPT NAME PARENT: fill in the {{...}} placeholders
render_prompt() {
  local text="$1"
  text="${text//\{\{name\}\}/$2}"
  text="${text//\{\{branch\}\}/agents/$2}"
  text="${text//\{\{parent_branch\}\}/$3}"
  text="${text//\{\{repo_root\}\}/$root}"
  local key
  for key in "${!prompt_vars[@]}"; do
    text="${text//\{\{$key\}\}/${prompt_vars[$key]}}"
  done
  printf '%s' "$text"
}

# approve_worktree_envrc NAME: let the agent's pane load the worktree's devshell.
#
# direnv approves an .envrc by path, so a worktree's copy is a new, unapproved path. Left
# unapproved, the pane's direnv hook unloads the root devshell it inherited (DIRENV_DIFF still
# names the root) and loads nothing in its place, so the agent runs on the plain login PATH: no
# bd, no project toolchain, and whatever claude the login profile happens to carry rather than the
# one this flake pins. Approving it extends no trust, because it is the same tracked .envrc as the
# root's, which the user has already allowed.
#
# Deliberately uses the direnv on PATH rather than a pinned one: the approval store is per-user
# and keyed by that binary's own hashing, so an approval written by a different build is one the
# user's hook would not honour.
#
# A silent no-op when direnv is absent or the root is not approved -- there is then no hook in the
# pane either, so the inherited devshell PATH survives and nothing needs fixing.
approve_worktree_envrc() {
  # Not `status`: that name is a readonly special variable in zsh, and panes run the login shell
  local name="$1" wt="$worktrees/$1" root_status
  command -v direnv >/dev/null || return 0
  [[ -f "$wt/.envrc" ]] || return 0
  # --json, not a grep over `direnv status`: its wording and its allow-state encoding have both
  # changed between releases (2.37 prints `allowed 0` where older builds printed `allowed true`),
  # and a mismatch there would disable this with no symptom except the bug coming back.
  root_status="$(cd "$root" && direnv status --json 2>/dev/null)" || return 0
  jq -e '.state.foundRC.allowed == 0' <<<"$root_status" >/dev/null 2>&1 || return 0
  direnv allow "$wt" >/dev/null 2>&1 ||
    echo "$name: could not approve $wt/.envrc; the agent may start without the devshell" >&2
}

# start_agent NAME PANE WORKSPACE KIND TIMEOUT PROMPT LOOP [AGENT_ARGS...]
start_agent() {
  local name="$1" pane="$2" workspace="$3" kind="$4" timeout="$5" prompt="$6" loop="$7"
  shift 7
  local out code

  # A beads actor per agent: `bd update --claim` is idempotent for the same actor, so agents
  # sharing the default (git user.name) could all "claim" one bead
  herdr pane run "$pane" "export PATH='$self_bin':\$PATH BEADS_ACTOR='$name'" >/dev/null
  if ! out="$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$timeout" -- "$@" 2>&1)"; then
    code="$(herdr_error_code "$out")"
    if [[ "$code" != agent_not_ready ]]; then
      echo "$name: failed to start: ${code:-$out}" >&2
      return 1
    fi
    # Blocked on a startup dialog (e.g. a folder trust prompt): leave it to the user
    echo "$name: waiting on a startup dialog; answer it in herdr (workspace $name)"
    if ! herdr agent wait "$name" --until idle --until "done" --timeout "$timeout" >/dev/null 2>&1; then
      echo "$name: not ready after ${timeout}ms${prompt:+; initial prompt NOT sent}" >&2
      return 1
    fi
  fi

  if ((loop)); then
    # The supervisor sends the prompt itself, so it can track each cycle from the start
    printf '%s' "$prompt" >"$state_dir/$name.prompt"
    if ! out="$(herdr tab create --workspace "$workspace" --label loop --no-focus)"; then
      echo "$name: failed to create the loop tab: $(herdr_error_code "$out")" >&2
      return 1
    fi
    herdr pane run "$(jq -r '.result.root_pane.pane_id' <<<"$out")" "'$self_bin/herdr-agents' supervise $name" >/dev/null
    echo "$name: started, looping (supervisor in tab \"loop\")"
  elif [[ -n "$prompt" ]]; then
    if ! out="$(herdr agent prompt "$name" "$prompt" 2>&1)"; then
      echo "$name: failed to send initial prompt: $(herdr_error_code "$out")" >&2
      return 1
    fi
    echo "$name: started, initial prompt sent"
  else
    echo "$name: started, idle"
  fi
}

cmd_list() {
  local agents
  agents="$(herdr agent list)"
  herdr worktree list --cwd "$root" |
    jq -r --arg dir "$worktrees/" --argjson agents "$agents" '
      [.result.worktrees[] | select(.path | startswith($dir))] as $wts
      | if ($wts | length) == 0 then "no agent worktrees under \($dir)" else
        (["NAME", "AGENT", "STATUS", "BRANCH", "WORKSPACE"] | @tsv),
        ($wts[] | (.path | ltrimstr($dir)) as $name
          | ([$agents.result.agents[]? | select(.name == $name)] | first) as $a
          | [$name, ($a.agent // "-"), ($a.agent_status // "not running"),
             (.branch // "detached"), (.open_workspace_id // "closed")] | @tsv)
        end' |
    column -t -s $'\t'
}

cmd_rm() {
  local all=0 delete_branch=0
  local -a names=() force=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --all) all=1 ;;
    --force) force=(--force) ;;
    --delete-branch) delete_branch=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown rm option: $1" ;;
    *) names+=("$1") ;;
    esac
    shift
  done
  if ((all)); then
    [[ ${#names[@]} -eq 0 ]] || die "use either --all or names, not both"
    for d in "$worktrees"/*/; do
      [[ -d "$d" ]] && names+=("$(basename "$d")")
    done
  fi
  [[ ${#names[@]} -gt 0 ]] || die "nothing to remove (give agent names or --all)"

  # Exit 2 is a tab that did not start, which does not stop us needing the session
  herdr-up "$root" >/dev/null || (($? == 2))
  local wts name path ws branch failed=0
  wts="$(herdr worktree list --cwd "$root")"
  for name in "${names[@]}"; do
    path="$worktrees/$name"
    if ! git -C "$root" worktree list --porcelain | grep -qxF "worktree $path"; then
      echo "$name: no worktree at .worktrees/$name" >&2
      failed=$((failed + 1))
      continue
    fi
    branch="$(git -C "$path" symbolic-ref --quiet --short HEAD || true)"
    ws="$(jq -r --arg p "$path" '.result.worktrees[] | select(.path == $p) | .open_workspace_id // empty' <<<"$wts")"
    # Refuse up front, so a worktree that stays never loses its agent's claims
    if [[ ${#force[@]} -eq 0 && -n "$(git -C "$path" status --porcelain)" ]]; then
      echo "$name: worktree has changes; rerun with --force to discard them" >&2
      failed=$((failed + 1))
      continue
    fi
    release_beads "$name" "$ws"

    # herdr removes the checkout and closes its workspace (stopping the agent); fall back
    # to git when the worktree has no open workspace
    if [[ -n "$ws" ]]; then
      herdr worktree remove --workspace "$ws" "${force[@]}" >/dev/null 2>&1 ||
        { echo "$name: worktree has changes; rerun with --force to discard them" >&2; failed=$((failed + 1)); continue; }
    else
      git -C "$root" worktree remove "${force[@]}" "$path" 2>/dev/null ||
        { echo "$name: worktree has changes; rerun with --force to discard them" >&2; failed=$((failed + 1)); continue; }
    fi
    rm -f "$state_dir/$name".*
    echo "$name: removed worktree"

    if ((delete_branch)) && [[ -n "$branch" ]]; then
      if git -C "$root" branch -d "$branch" >/dev/null 2>&1; then
        echo "$name: deleted branch $branch"
      else
        echo "$name: kept unmerged branch $branch (delete with: git branch -D $branch)"
      fi
    fi
  done
  rmdir "$worktrees" 2>/dev/null || true
  ((failed == 0))
}

# release_beads NAME [WORKSPACE]: put back the in-progress beads a removed agent leaves behind,
# those assigned to it or tied (agent_pane) to a pane of its workspace, so `bd ready` offers
# them again. A pane-tied bead assigned to another agent is left alone.
release_beads() {
  local name="$1" ws="$2" panes='[]' others beads id assignee
  if [[ -n "$ws" ]]; then
    panes="$(herdr pane list --workspace "$ws" 2>/dev/null | jq -c '[.result.panes[]?.pane_id]' || echo '[]')"
  fi
  others="$(find "$worktrees" -mindepth 1 -maxdepth 1 -type d ! -name "$name" -printf '%f\n' |
    jq -Rsc 'split("\n") | map(select(. != ""))')"
  beads="$(bd list --status=in_progress --json 2>/dev/null |
    jq -r --arg n "$name" --argjson panes "$panes" --argjson others "$others" '
      .[] | (.assignee // "") as $a
      | select($a == $n or ((.metadata.agent_pane // "") as $p
        | any($panes[]; . == $p) and (any($others[]; . == $a) | not)))
      | [.id, $a] | @tsv')" || { echo "$name: could not list in-progress beads; none released" >&2; return 0; }
  while IFS=$'\t' read -r id assignee; do
    [[ -n "$id" ]] || continue
    # Unclaim as the holder, and only while it still holds the bead
    if [[ -n "$assignee" ]]; then
      bd --actor "$assignee" unclaim "$id" --if-assignee "$assignee" --reason "herdr-agents rm $name" >/dev/null 2>&1 ||
        { echo "$name: could not release $id (assigned to $assignee)" >&2; continue; }
    else
      bd update "$id" --status open >/dev/null 2>&1 || { echo "$name: could not release $id" >&2; continue; }
    fi
    bd update "$id" --unset-metadata agent_pane >/dev/null 2>&1 || true
    echo "$name: released bead $id"
  done <<<"$beads"
  bdi_changed
}

cmd_merge() {
  local branch parent target head locked_parent wt="" line path=""
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "merge: HEAD is detached; run it on the agent branch"
  parent="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" ||
    die "merge: $branch has no parent branch (set one with: git branch --set-upstream-to=<parent>)"
  git show-ref --verify --quiet "refs/heads/$parent" || die "merge: parent '$parent' is not a local branch"
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] ||
    die "merge: $branch has uncommitted changes; commit them first"

  # One merge at a time across all agents sharing this repository
  exec 9>"$(git rev-parse --path-format=absolute --git-common-dir)/herdr-agents-merge.lock"
  flock 9

  head="$(git rev-parse HEAD)"
  locked_parent="$(git rev-parse "refs/heads/$parent")"
  if [[ "$locked_parent" == "$head" ]]; then
    echo "merge: $parent already contains $branch"
    return 0
  fi
  if ! git merge-base --is-ancestor "$locked_parent" "$head"; then
    echo "merge: $parent has moved on since $branch forked; run \`git rebase $parent\`," \
      "resolve any conflicts, re-run the checks, then run \`herdr-agents merge\` again" >&2
    exit 3
  fi

  # bd keeps its database and JSONL export in the repo root, so .beads/ is dirty there whenever
  # a bead changes. Agent commits must leave it alone or the fast-forward would clash with it.
  if [[ -n "$(git diff --name-only "$locked_parent" "$head" -- .beads/)" ]]; then
    echo "merge: $branch changes .beads/, which agents must not commit (bd exports to the repo" \
      "root, not worktrees). Drop those changes, e.g.: git reset --soft $parent &&" \
      "git restore --staged --worktree --source=$parent -- .beads/ && git commit," \
      "then run \`herdr-agents merge\` again" >&2
    exit 4
  fi

  # Find a worktree that has the parent branch checked out
  while IFS= read -r line; do
    case "$line" in
    "worktree "*) path="${line#worktree }" ;;
    "branch refs/heads/$parent") wt="$path" ;;
    esac
  done < <(git worktree list --porcelain)

  if [[ -n "$wt" ]]; then
    # Advances the branch and that checkout together; refuses to touch local edits there
    git -C "$wt" merge --ff-only --quiet "$head" ||
      die "merge: could not fast-forward $parent in $wt (local changes in the way?)"
    target="$parent in $wt"
  else
    git update-ref -m "herdr-agents merge $branch" "refs/heads/$parent" "$head" "$locked_parent"
    target="$parent"
  fi
  echo "merge: fast-forwarded $target to $branch ($(git rev-parse --short "$head"))"
}

# The agent name for the worktree this command runs in
current_agent() {
  local top
  top="$(git rev-parse --show-toplevel)"
  [[ "$(dirname "$top")" == "$worktrees" ]] || die "not inside an agent worktree under $worktrees"
  basename "$top"
}

cmd_report() {
  local status="${1:-}" name
  [[ "$status" =~ ^(next|wait|empty)$ ]] || die "usage: herdr-agents report (next | wait | empty)"
  name="$(current_agent)"
  mkdir -p "$state_dir"
  printf '%s\n' "$status" >"$state_dir/$name.state.tmp"
  mv "$state_dir/$name.state.tmp" "$state_dir/$name.state"
  if [[ -f "$state_dir/$name.prompt" ]]; then
    echo "report: recorded '$status'; the loop supervisor acts on it when this turn ends"
  else
    echo "report: recorded '$status' (no loop supervisor for $name, so nothing else happens)"
  fi
}

# supervise NAME: drive a --loop agent, one prompt per cycle (runs in the agent's "loop" tab)
cmd_supervise() {
  local name="${1:?usage: herdr-agents supervise NAME}" cycle=1 out
  # On `report wait`: poll every wait_poll seconds, give up waiting after wait_max
  local wait_poll=30 wait_max=900
  local prompt_file="$state_dir/$name.prompt" state_file="$state_dir/$name.state"
  [[ -f "$prompt_file" ]] || die "supervise: no saved prompt for $name"

  log() { printf '%s %s: %s\n' "$(date +%T)" "$name" "$*"; }
  notify() { herdr notification show "$name" --body "$1" --sound request >/dev/null 2>&1 || true; }
  alive() { herdr agent get "$name" >/dev/null 2>&1; }
  # Sorted ids of the beads in progress, or "?" when bd cannot be read
  in_progress() { bd list --status=in_progress --json 2>/dev/null | jq -r '.[].id' | sort || echo '?'; }
  # Blocks until a bead in progress now is no longer (closed, released, reopened), which is
  # what unblocks waiting work, or until wait_max passes; fails once the agent is gone
  await_unblock() {
    local before now waited=0
    before="$(in_progress)"
    log "waiting for blocked work: a bead to leave in_progress (${before//$'\n'/ }) or ${wait_max}s"
    while ((waited < wait_max)); do
      sleep "$wait_poll"
      waited=$((waited + wait_poll))
      alive || return 1
      now="$(in_progress)"
      [[ "$now" != "?" ]] || continue
      [[ "$before" != "?" ]] || before="$now"
      if [[ -n "$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$now"))" ]]; then
        log "in-progress beads changed after ${waited}s; checking for work again"
        return 0
      fi
      before="$now"
    done
    log "still blocked after ${wait_max}s; checking for work again"
  }
  # Runs `rm` for this agent (spawned with --rm-on-empty). rm closes the agent's workspace, and
  # with it this tab, so it runs in a session of its own and reports by notification and a log
  # outside the per-agent state that rm deletes.
  remove_when_done() {
    local rm_log="$state_dir/rm-on-empty.log"
    log "removing the agent (--rm-on-empty); log: $rm_log"
    # shellcheck disable=SC2016 # expanded by the inner shell
    setsid -f "$BASH" -c '
      name="$1" self="$2" rm_log="$3"
      cd "$4" || exit 1
      notify() { herdr notification show "$name" --body "$1" --sound request >/dev/null 2>&1 || true; }
      if { echo "$(date "+%F %T") $name: herdr-agents rm --delete-branch"
        "$self" rm "$name" --delete-branch 2>&1; } >>"$rm_log"; then
        notify "no work left; agent removed"
      else
        notify "no work left, but removing it failed (see $rm_log)"
      fi
    ' remove-when-done "$name" "$self_bin/herdr-agents" "$rm_log" "$root" </dev/null >/dev/null 2>&1
  }
  # Clears the agent's context and sends the prompt for the next cycle
  next_cycle() {
    cycle=$((cycle + 1))
    # /clear never shows as working, so it is sent without --wait
    herdr agent prompt "$name" /clear >/dev/null 2>&1 || true
    sleep 2
    herdr agent wait "$name" --until idle --until "done" >/dev/null 2>&1 || return 1
    send_prompt
  }
  # Sends the prompt and blocks until that turn has ended (permission dialogs keep it waiting)
  send_prompt() {
    rm -f "$state_file"
    log "cycle $cycle: sending prompt"
    if ! out="$(herdr agent prompt "$name" "$(<"$prompt_file")" --wait --until idle --until "done" 2>&1)"; then
      log "prompt not confirmed ($(herdr_error_code "$out")); watching the agent"
    fi
  }

  send_prompt
  while alive; do
    herdr agent wait "$name" --until idle --until "done" >/dev/null 2>&1 || break
    case "$(cat "$state_file" 2>/dev/null || true)" in
    next)
      log "cycle finished; clearing context"
      next_cycle || break
      ;;
    wait)
      rm -f "$state_file"
      await_unblock || break
      next_cycle || break
      ;;
    empty)
      rm -f "$state_file"
      # The agent's work may have finished an epic; close every epic whose children are done
      if out="$(bd epic close-eligible --reason "All children completed (herdr-agents loop $name)" 2>&1)"; then
        log "${out//$'\n'/ }"
      else
        log "bd epic close-eligible failed: ${out//$'\n'/ }"
      fi
      log "no work left; loop finished after $cycle cycle(s)"
      if [[ -f "$state_dir/$name.rm-on-empty" ]]; then
        remove_when_done
      else
        notify "no work left; loop finished after $cycle cycle(s)"
      fi
      return 0
      ;;
    *)
      log "turn ended without a report; waiting for the agent to work again"
      notify "stopped without reporting; it may need input"
      herdr agent wait "$name" --until working >/dev/null 2>&1 || break
      log "agent is working again"
      ;;
    esac
  done
  log "agent is gone; supervisor exiting"
}

# Ask a running bdi to re-read the project now rather than at its next poll
bdi_changed() {
  local sock="${XDG_RUNTIME_DIR:-}/beady-eye/changes.sock"
  [[ -S "$sock" ]] || return 0
  printf '%s\n' "$project" | socat - UNIX-CONNECT:"$sock" >/dev/null 2>&1 || true
}

# This pane and the source tag herdr metadata is reported under (herdr:<agent kind>)
pane_identity() {
  pane="${HERDR_PANE_ID:?not inside a herdr pane (HERDR_PANE_ID is unset)}"
  source="herdr:$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent // empty')"
  [[ "$source" != "herdr:" ]] || source="herdr:agent"
}

cmd_claim() {
  local id="${1:?usage: herdr-agents claim ID}" pane source
  pane_identity
  # Claim as this agent (from its agents/<name> branch), not the shared default actor, so a
  # bead another agent already holds is refused instead of claimed again
  local branch actor=()
  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  if [[ "$branch" == agents/* ]]; then
    actor=(--actor "${branch#agents/}")
  fi
  bd "${actor[@]}" update "$id" --claim || die "claim: could not claim $id"
  bd update "$id" --set-metadata agent_pane="$pane" >/dev/null
  herdr pane report-metadata "$pane" --source "$source" --display-agent "$id" >/dev/null
  bdi_changed
  echo "claim: $id claimed by pane $pane"
}

cmd_release() {
  local id="${1:?usage: herdr-agents release ID}" pane source
  pane_identity
  bd update "$id" --unset-metadata agent_pane >/dev/null || die "release: could not update $id"
  herdr pane report-metadata "$pane" --source "$source" --clear-display-agent >/dev/null
  bdi_changed
  echo "release: $id no longer tied to pane $pane"
}

# preset_file NAME: the file for preset NAME, from the project or else built in
preset_file() {
  local f
  for f in "$presets/$1.md" "$builtin_presets/$1.md"; do
    if [[ -f "$f" ]]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

cmd_presets() {
  local f name found=0
  local -A seen=()
  for f in "$presets"/*.md "$builtin_presets"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .md)"
    [[ -z "${seen[$name]:-}" ]] || continue
    seen[$name]=1
    found=1
    local needs origin=built-in
    [[ "$f" != "$presets/"* ]] || origin=project
    needs="$(grep -oE '\{\{[a-z][a-z0-9_]*\}\}' "$f" | tr -d '{}' | sort -u |
      grep -vxF -f <(printf '%s\n' "${builtin_vars[@]}") | sed 's/.*/--var &=.../' | tr '\n' ' ' || true)"
    printf '%-20s %-9s %s\n' "$name" "$origin" "$(head -n1 "$f" | sed 's/^#* *//')"
    [[ -z "$needs" ]] || printf '%-20s %-9s needs: %s\n' "" "" "${needs% }"
  done
  ((found)) || echo "no presets in .herdr/prompts/ or built in"
}

case "${1:-}" in
spawn) shift; cmd_spawn "$@" ;;
list | ls) cmd_list ;;
rm | remove) shift; cmd_rm "$@" ;;
merge) cmd_merge ;;
report) shift; cmd_report "$@" ;;
claim) shift; cmd_claim "$@" ;;
release) shift; cmd_release "$@" ;;
supervise) shift; cmd_supervise "$@" ;;
presets) cmd_presets ;;
-h | --help | help | "") usage ;;
*) usage >&2; exit 2 ;;
esac

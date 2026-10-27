# project-files: the project files devflake owns and replaces on every run, shared by the
# devflake commands. Sourced into each command's writeShellApplication text after the preamble
# that sets $share, so every function runs in the project root and reports with note().
# $cmd names the command in its messages (default: devflake-init).

die() {
  echo "${cmd:-devflake-init}: $*" >&2
  exit 1
}
note() { echo "${cmd:-devflake-init}: $*"; }

# gitignore_has LINE: whether .gitignore already carries LINE or an obvious spelling of it -- the
# pattern without its leading / anchor, without its trailing dir/ slash, or both. /result and
# /result-* also accept result*, which covers both. Deliberately no more than that: this is a
# check against duplicating a line, not an implementation of gitignore matching.
gitignore_has() {
  local bare=${1#/}
  bare=${bare%/}
  local spellings=("$1" "$bare" "/$bare" "$bare/" "/$bare/")
  case $1 in /result | /result-*) spellings+=('result*' '/result*') ;; esac
  local s
  for s in "${spellings[@]}"; do
    grep -qxF -- "$s" .gitignore 2>/dev/null && return 0
  done
  return 1
}

# ensure_gitignore: append the devflake ignore lines that .gitignore lacks, under one comment
ensure_gitignore() {
  local line ignored=()
  # .beads/issues.jsonl: bd rewrites this export on every commit (its pre-commit hook refreshes it
  # when export.auto is on), and `herdr-agents merge` refuses a branch that touches .beads/, so
  # tracking it would make every agent branch unmergeable.
  for line in /.worktrees/ .direnv/ /result /result-* .beads/issues.jsonl; do
    if ! gitignore_has "$line"; then
      ignored+=("$line")
    fi
  done
  if ((${#ignored[@]})); then
    if [[ -s .gitignore && -n "$(tail -c1 .gitignore)" ]]; then
      echo >>.gitignore
    fi
    printf '\n# devflake: agent worktrees, direnv, nix build results, the beads export\n' >>.gitignore
    printf '%s\n' "${ignored[@]}" >>.gitignore
    note "added to .gitignore: ${ignored[*]}"
  fi
}

# install_skills: share/skills/*/SKILL.md into .claude/skills, .agents/skills (and
# .opencode/skills when the project has .opencode), overwriting what is there
install_skills() {
  local skill dir skill_dirs=(.claude/skills .agents/skills)
  [[ ! -d .opencode ]] || skill_dirs+=(.opencode/skills)
  for skill in "$share"/skills/*/; do
    skill="$(basename "$skill")"
    for dir in "${skill_dirs[@]}"; do
      install -D -m 644 "$share/skills/$skill/SKILL.md" "$dir/$skill/SKILL.md"
    done
    note "installed skill $skill into ${skill_dirs[*]}"
  done
}

block_begin='<!-- BEGIN DEVFLAKE'
block_end='<!-- END DEVFLAKE'
# upsert_block FILE: replace the devflake block in FILE, or append it
upsert_block() {
  local file="$1" tmp line in_block=0 replaced=0
  [[ -e "$file" ]] || : >"$file"
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((in_block)); then
      [[ "$line" != "$block_end"* ]] || in_block=0
      continue
    fi
    if [[ "$line" == "$block_begin"* ]]; then
      cat "$share/agents-block.md" >>"$tmp"
      in_block=1 replaced=1
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  if ((!replaced)); then
    [[ ! -s "$tmp" ]] || echo >>"$tmp"
    cat "$share/agents-block.md" >>"$tmp"
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# upsert_agents_block: the devflake block in AGENTS.md and CLAUDE.md (replaced on every run)
upsert_agents_block() {
  local f
  for f in AGENTS.md CLAUDE.md; do
    upsert_block "$f"
  done
  note "updated the devflake block in AGENTS.md and CLAUDE.md"
}

# devflake-upgrade: move a project's devflake input to a newer ref.
# Packaged by devflake's flake.nix via writeShellApplication, which sets $share and $cmd and sources
# project-files.sh (die, note and the devflake-managed files) ahead of this script, and $rev, the
# commit it was built from. It depends only on its runtimeInputs, so it runs from outside the
# project's devshell -- the thing being replaced -- with one exception: the re-lock uses the nix
# the user invoked it with, which is the one that works with their daemon, config and lockfile.

usage() {
  cat <<'EOF'
Usage: devflake-upgrade [REF] [--dry-run]

Run in the project (any directory of its git repository). Points the project's devflake input at
REF, or at the latest release tag (vX.Y.Z) of the repository it already uses, so a fork upgrades
against itself. Never commits.

  REF           a tag, branch or commit of that repository (default: its latest vX.Y.Z tag)

Options:
  --dry-run     report the current input, its locked rev and the target; change nothing
  -h, --help    show this help
EOF
}

ref="" dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run) dry_run=1; shift ;;
  -h | --help) usage; exit 0 ;;
  -*) usage >&2; exit 2 ;;
  *)
    [[ -z "$ref" ]] || { usage >&2; exit 2; }
    ref="$1"
    shift
    ;;
  esac
done

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository; run this in the project"
cd "$root"
[[ -e flake.nix ]] || die "no flake.nix in $root; is this a devflake project? (devflake-init sets one up)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- the current input. Only the assignment itself, anchored, so that a comment or any other
# mention of the string is never read or rewritten.
assign_re='^[[:space:]]*(inputs\.)?devflake\.url = "([^"]*)";'
lines="$(grep -nE "$assign_re" flake.nix || true)"
[[ -n "$lines" ]] || die "flake.nix has no devflake.url = \"...\"; assignment to upgrade"
(($(wc -l <<<"$lines") == 1)) || die "flake.nix assigns devflake.url more than once; edit it by hand:
$lines"
lineno="${lines%%:*}"
current="$(sed -nE "${lineno}s/$assign_re.*/\\2/p" flake.nix)"

# github:owner/repo or github:owner/repo/ref. Anything else is left to the user rather than guessed.
ref_chars='[A-Za-z0-9._/-]+'
if [[ "$current" =~ ^github:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(/$ref_chars)?$ ]]; then
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}"
else
  die "flake.nix line $lineno: devflake.url = \"$current\" is not github:owner/repo[/ref]; upgrade it by hand"
fi
remote="https://github.com/$owner/$repo.git"

# lock_rev: the rev flake.lock holds for the devflake input (a root input naming its node), or
# nothing when it is not locked
lock_rev() {
  [[ -e flake.lock ]] || return 0
  jq -r '.root as $r | .nodes as $n | ($n[$r].inputs.devflake // empty) as $i
    | if ($i | type) == "string" then $n[$i].locked.rev // empty else empty end' flake.lock 2>/dev/null || true
}
locked_rev="$(lock_rev)"

# ls_remote ARGS...: git ls-remote against the repository, failing with a readable message
ls_remote() {
  local out
  if ! out="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$@" "$remote" 2>&1)"; then
    die "could not query $remote ($(tail -n1 <<<"$out")); check the network and that the repository exists"
  fi
  printf '%s\n' "$out"
}

# --- the target
if [[ -z "$ref" ]]; then
  tags="$(ls_remote --tags --refs)"
  ref="$(cut -f2 <<<"$tags" | cut -d/ -f3- | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)"
  [[ -n "$ref" ]] || die "$owner/$repo has no release tags (vX.Y.Z) yet; name a ref: $cmd REF"
  note "latest release of $owner/$repo is $ref"
else
  [[ "$ref" =~ ^$ref_chars$ ]] || die "'$ref' is not a ref devflake-upgrade can write into github:$owner/$repo/<ref>"
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    # A commit is not listed by ls-remote; fetching it is the only check GitHub allows
    git init -q --bare "$work/probe"
    GIT_TERMINAL_PROMPT=0 git -C "$work/probe" fetch -q --depth 1 "$remote" "$ref" 2>/dev/null ||
      die "commit $ref not found in $owner/$repo (or $remote could not be reached)"
  else
    refs="$(ls_remote --tags --heads)"
    # Compared as fixed strings: a ref may hold regex characters (the dots of a version)
    grep -qxF -e "refs/tags/$ref" -e "refs/heads/$ref" \
      <<<"$(cut -f2 <<<"$refs")" ||
      die "no tag or branch '$ref' in $owner/$repo"
  fi
fi
target="github:$owner/$repo/$ref"

if ((dry_run)); then
  note "current input: $current"
  note "locked rev:    ${locked_rev:-(not locked)}"
  note "target:        $target"
  note "dry run; nothing changed"
  exit 0
fi

command -v nix >/dev/null || die "nix is not on PATH; it is needed to re-lock the devflake input"

# The flake files as they were, restored if the re-lock fails so a bad ref changes nothing
cp -f flake.nix "$work/flake.nix"
[[ ! -e flake.lock ]] || cp -f flake.lock "$work/flake.lock"
restore() {
  cp -f "$work/flake.nix" flake.nix
  if [[ -e "$work/flake.lock" ]]; then
    cp -f "$work/flake.lock" flake.lock
  else
    rm -f flake.lock
  fi
}

# --- rewrite the assignment's quoted value, on that one line only
if [[ "$current" == "$target" ]]; then
  note "devflake.url is already $target"
else
  sed -i -E "${lineno}s|^([[:space:]]*(inputs\\.)?devflake\\.url = \")[^\"]*(\";)|\\1$target\\3|" flake.nix
  note "flake.nix: devflake.url $current -> $target"
fi

# --- re-lock. Done here rather than left to the next evaluation, so that a ref which does not
# evaluate is caught now and the move can be reported. Older nix has no `flake update INPUT`.
nix_flake() { nix --extra-experimental-features 'nix-command flakes' flake "$@"; }
note "re-locking the devflake input"
if ! out="$(nix_flake update devflake 2>&1)" &&
  ! out_old="$(nix_flake lock --update-input devflake 2>&1)"; then
  restore
  # Either error may be the one that matters: which form this nix rejects is not known
  printf '$ nix flake update devflake\n%s\n$ nix flake lock --update-input devflake\n%s\n' \
    "$out" "$out_old" >&2
  die "re-locking devflake at $target failed; flake.nix and flake.lock are as they were"
fi
new_rev="$(lock_rev)"

# --- refresh the devflake-managed files, noting which of them this changes
skill_dirs=(.claude/skills .agents/skills)
[[ ! -d .opencode ]] || skill_dirs+=(.opencode/skills)
managed=(AGENTS.md CLAUDE.md .gitignore)
for skill in "$share"/skills/*/; do
  for dir in "${skill_dirs[@]}"; do
    managed+=("$dir/$(basename "$skill")/SKILL.md")
  done
done
# digest FILE: its content hash, or - when it does not exist
digest() { if [[ -e "$1" ]]; then sha256sum <"$1" | cut -d' ' -f1; else echo -; fi; }
before=()
for f in "${managed[@]}"; do before+=("$(digest "$f")"); done

install_skills
upsert_agents_block
ensure_gitignore

changed=() created=()
for i in "${!managed[@]}"; do
  f="${managed[$i]}"
  [[ "$(digest "$f")" != "${before[$i]}" ]] || continue
  changed+=("$f")
  # Flakes ignore untracked files: make new ones visible to nix without staging their content
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || created+=("$f")
done
((${#created[@]} == 0)) || git add --intent-to-add -- "${created[@]}"

# --- report
cat <<EOF

devflake upgraded; nothing is staged or committed (review with git diff):
  input:       $current -> $target
  locked rev:  ${locked_rev:-(not locked)} -> ${new_rev:-(not locked)}
  changed:     ${changed[*]:-no devflake-managed files}
EOF
((${#created[@]} == 0)) || echo "  new:         ${created[*]} (intent-to-add, so nix can see them)"
# The managed files come from the devflake this command was built from, which is the newly locked
# one only when it was run from the target
if [[ "$rev" =~ ^[0-9a-f]{40}$ && -n "$new_rev" && "$rev" != "$new_rev" ]]; then
  cat <<EOF

  The managed files come from devflake ${rev:0:12}, which this command was built from, not from
  the newly locked ${new_rev:0:12}. To refresh them from that version instead, run its upgrade:
    nix run github:$owner/$repo/$new_rev#upgrade -- $ref
EOF
fi
cat <<EOF

Next steps:
  1. Review and commit the changes (git status, git diff).
  2. Re-enter the devshell (\`direnv reload\`, or exit and \`nix develop\`): the running one is
     still the old devflake.
  3. If the project had a herdr session of its own and the new version shares one, the old
     server keeps running orphaned. Check \`herdr session list\`: a stale session is stopped with
     \`herdr session stop <name>\` and removed with \`herdr session delete <name>\`.
EOF

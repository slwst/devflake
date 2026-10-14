# devflake-upgrade: move a project's devflake input to a newer ref.
# Packaged by devflake's flake.nix via writeShellApplication, which sets $share and $cmd and sources
# project-files.sh (die, note and the devflake-managed files) ahead of this script. It depends only
# on its runtimeInputs, so it runs from outside the project's devshell -- the thing being replaced.

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

# The rev flake.lock holds for the devflake input (a root input naming its node), if locked
locked_rev=""
if [[ -e flake.lock ]]; then
  locked_rev="$(jq -r '.root as $r | .nodes as $n | ($n[$r].inputs.devflake // empty) as $i
    | if ($i | type) == "string" then $n[$i].locked.rev // empty else empty end' flake.lock 2>/dev/null || true)"
fi

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
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git init -q --bare "$tmp"
    GIT_TERMINAL_PROMPT=0 git -C "$tmp" fetch -q --depth 1 "$remote" "$ref" 2>/dev/null ||
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

# --- rewrite the assignment's quoted value, on that one line only
if [[ "$current" == "$target" ]]; then
  note "devflake.url is already $target"
else
  sed -i -E "${lineno}s|^([[:space:]]*(inputs\\.)?devflake\\.url = \")[^\"]*(\";)|\\1$target\\3|" flake.nix
  note "flake.nix: devflake.url $current -> $target"
fi

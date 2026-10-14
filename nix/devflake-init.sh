# devflake-init: set up a new or existing project for the devflake workflow.
# Packaged by devflake's flake.nix via writeShellApplication, which sets $share and $template_dir.
# Every step is skipped when already done, so it is safe to rerun (e.g. to refresh the skills).

usage() {
  cat <<'EOF'
Usage: devflake-init [options]

Run in the project (any directory of its git repository; outside one, `git init` runs here).
Each step is skipped when already done:

  .beads/       `bd init`, which also writes the beads sections of AGENTS.md/CLAUDE.md and the
                Claude, Codex and Cursor hooks, and commits what it wrote (it runs first, so
                that commit holds only its own files; it refuses to run over staged changes)
  flake.nix     from devflake's template, named after the project (an existing flake that does
                not use devflake is left alone; the snippet to add is printed instead)
  .envrc        `use flake`, for direnv
  .gitignore    /.worktrees/ (agent worktrees), .direnv/, /result*
  openspec/     `openspec init` for the agent tools in --tools
  skills        openspec-to-epic, into .claude/skills, .agents/skills (and .opencode/skills)
  AGENTS.md     the devflake block, also in CLAUDE.md (replaced on every run)
  bootstrap     for an existing project, an epic (label devflake-bootstrap) whose beads bring its
                build and tests into the flake

Options:
  --name NAME       herdr session/workspace name (default: the repo directory, sanitized)
  --prefix PREFIX   beads issue prefix for `bd init` (default: bd's, the directory name)
  --tools LIST      openspec agent tools (default: claude,codex,opencode)
  --bootstrap       create the bootstrap epic even if the project looks new
  --no-bootstrap    never create the bootstrap epic
  -h, --help        show this help
EOF
}

die() {
  echo "devflake-init: $*" >&2
  exit 1
}
note() { echo "devflake-init: $*"; }

name="" prefix="" tools="claude,codex,opencode" bootstrap=auto
while [[ $# -gt 0 ]]; do
  case "$1" in
  --name) name="${2:?--name needs a value}"; shift 2 ;;
  --prefix) prefix="${2:?--prefix needs a value}"; shift 2 ;;
  --tools) tools="${2:?--tools needs a value}"; shift 2 ;;
  --bootstrap) bootstrap=yes; shift ;;
  --no-bootstrap) bootstrap=no; shift ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
  esac
done

if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  note "not inside a git repository; running git init in $PWD (flakes only see git-tracked files)"
  git init -q
  root="$PWD"
fi
cd "$root"

if [[ -z "$name" ]]; then
  name="$(basename "$root" | tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9_-]+/-/g; s/^[^a-z]+//; s/-+$//' | cut -c1-32)"
  [[ -n "$name" ]] || name=project
fi
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "--name must match [a-z][a-z0-9_-]{0,31} (it names the herdr session)"

# An existing project has files beyond what devflake and the tools it runs create. Decided before
# any of them are written.
scaffold_re='^$|^(\.gitignore|\.envrc|flake\.(nix|lock)|result.*|README[^/]*|LICENSE[^/]*|AGENTS\.md|CLAUDE\.md|\.beads\.gate\.lock)$|^(\.beads|\.claude|\.codex|\.cursor|\.agents|\.opencode|\.herdr|\.direnv|openspec)/'
project_files="$(git ls-files --cached --others --exclude-standard | grep -vE "$scaffold_re" || true)"
existing=0
[[ -z "$project_files" ]] || existing=1

created=()

# --- beads. First, because bd init commits the files it writes (and anything else it staged):
# that commit should hold only bd's own files.
if [[ ! -d .beads ]]; then
  git diff --cached --quiet ||
    die "bd init commits what is staged; commit or unstage your staged changes first (git status)"
  note "initializing beads (bd init)"
  head_before="$(git rev-parse -q --verify HEAD || true)"
  bd init --non-interactive -q ${prefix:+--prefix "$prefix"}
  head_after="$(git rev-parse -q --verify HEAD || true)"
  if [[ "$head_after" != "$head_before" ]]; then
    note "bd init committed its own files as $(git log -1 --format='%h "%s"')"
  fi
  # Nothing in the devflake toolchain reads .beads/issues.jsonl -- bdi and mg both drive the bd
  # CLI -- but bd rewrites the export on every bead change and again in its pre-commit hook,
  # and `herdr-agents merge` refuses a branch that touches .beads/, so an agent running
  # `git add -A` would leave itself unable to merge. Only on a fresh init: on a rerun the
  # project keeps whatever it has chosen.
  bd config set export.auto false >/dev/null
  note "turned off beads' JSONL auto-export (export.auto=false in .beads/config.yaml)"
else
  note "beads already initialized"
fi

# --- flake.nix
if [[ ! -e flake.nix ]]; then
  sed "s/my-project/$name/g" "$template_dir/flake.nix" >flake.nix
  created+=(flake.nix)
  note "wrote flake.nix (project name: $name)"
elif grep -q devflake flake.nix; then
  # `nix flake init -t devflake` writes the template verbatim, leaving its placeholder for this
  # step to name. Match it only as the assignment the template makes, so that nothing else
  # mentioning the string is touched -- a comment, a usage example (devflake's own flake.nix has
  # one), or a project that happens to be called my-project.
  placeholder='^[[:space:]]*(description|name) = "my-project";'
  if grep -qE "$placeholder" flake.nix; then
    sed -i -E "/$placeholder/ s/\"my-project\"/\"$name\"/" flake.nix
    note "named the project '$name' in flake.nix"
  else
    note "flake.nix already uses devflake; left as is"
  fi
else
  note "flake.nix exists and does not use devflake; left as is. To add it:"
  cat <<EOF

  inputs.devflake.url = "$(sed -n 's/^ *devflake\.url = "\(.*\)";/\1/p' "$template_dir/flake.nix")";

  devShells.default = devflake.lib.mkShell {
    inherit pkgs;
    name = "$name";
    packages = [ /* the toolchain your current devShell provides */ ];
    # inputsFrom, env vars and shellHook are passed through to pkgs.mkShell
  };

EOF
fi

# --- .envrc
if [[ ! -e .envrc ]]; then
  cp -f "$template_dir/.envrc" .envrc
  chmod u+w .envrc
  created+=(.envrc)
  note "wrote .envrc (run \`direnv allow\` to use it)"
elif ! grep -q 'use flake' .envrc; then
  note ".envrc exists without \`use flake\`; left as is"
fi

# --- .gitignore
ignored=()
# .beads/issues.jsonl: bd rewrites this export on every commit (its pre-commit hook refreshes it
# when export.auto is on), and `herdr-agents merge` refuses a branch that touches .beads/, so
# tracking it would make every agent branch unmergeable.
for line in /.worktrees/ .direnv/ /result /result-* .beads/issues.jsonl; do
  if ! grep -qxF -- "$line" .gitignore 2>/dev/null; then
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

# --- openspec
if [[ ! -d openspec ]]; then
  note "initializing openspec for $tools"
  openspec init --tools "$tools" --no-animation </dev/null
else
  note "openspec already initialized"
fi

# --- skills (devflake-managed: overwritten on every run)
skill_dirs=(.claude/skills .agents/skills)
[[ ! -d .opencode ]] || skill_dirs+=(.opencode/skills)
for skill in "$share"/skills/*/; do
  skill="$(basename "$skill")"
  for dir in "${skill_dirs[@]}"; do
    install -D -m 644 "$share/skills/$skill/SKILL.md" "$dir/$skill/SKILL.md"
  done
  note "installed skill $skill into ${skill_dirs[*]}"
done

# --- AGENTS.md / CLAUDE.md devflake block
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
for f in AGENTS.md CLAUDE.md; do
  upsert_block "$f"
done
note "updated the devflake block in AGENTS.md and CLAUDE.md"

# --- bootstrap epic
# bead NAME [BD_CREATE_ARGS...]: create a bead from share/bootstrap/NAME.md (# title, then body)
bead() {
  local f="$share/bootstrap/$1.md"
  shift
  bd create "$(head -n1 "$f" | sed 's/^# *//')" -d "$(tail -n +2 "$f")" --silent "$@"
}
epic=""
if [[ "$bootstrap" == yes || ("$bootstrap" == auto && "$existing" == 1) ]]; then
  epic="$(bd list --all --type epic --label devflake-bootstrap --json | jq -r '.[0].id // empty')"
  if [[ -n "$epic" ]]; then
    note "bootstrap epic $epic already exists"
  else
    epic="$(bead epic -t epic -l devflake-bootstrap -p 1)"
    toolchain="$(bead toolchain --parent "$epic")"
    build="$(bead build --parent "$epic" --deps "blocked-by:$toolchain")"
    tests="$(bead tests --parent "$epic" --deps "blocked-by:$build")"
    lint="$(bead lint --parent "$epic" --deps "blocked-by:$build")"
    bead docs --parent "$epic" --deps "blocked-by:$tests,blocked-by:$lint" >/dev/null
    note "created bootstrap epic $epic (bd show $epic)"
  fi
elif [[ "$bootstrap" == auto ]]; then
  note "no project files found, so no bootstrap epic (rerun with --bootstrap to create one)"
fi

# Flakes ignore untracked files, so make the new ones visible to nix without staging their content
if ((${#created[@]})); then
  git add --intent-to-add -- "${created[@]}"
  note "marked ${created[*]} as intent-to-add in git so nix can see them"
fi

cat <<EOF

Next steps:
  1. Review and commit the changes (git status).
  2. Enter the devshell: \`direnv allow\` or \`nix develop\`. This starts the herdr session
     '$name' with the parade (mg), captain (claude) and beads (bdi) tabs; attach with \`herdr\`.
EOF
if [[ -n "$epic" ]]; then
  cat <<EOF
  3. Bring the build and tests into the flake by working the bootstrap epic, e.g. ask the
     captain, or run:
       herdr-agents spawn --preset bd-epic --var epic=$epic --loop --rm-on-empty
  4. Then: /opsx:propose a change, turn it into an epic (openspec-to-epic skill), spawn agents.
EOF
else
  cat <<EOF
  3. Add the project's toolchain to \`packages\` in flake.nix, then: /opsx:propose a change,
     turn it into an epic (openspec-to-epic skill), spawn agents.
EOF
fi

# devflake-init: set up a new or existing project for the devflake workflow.
# Packaged by devflake's flake.nix via writeShellApplication, which sets $share and $template_dir
# and sources project-files.sh (die, note and the devflake-managed files) ahead of this script.
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
                build and tests into the flake; skipped when its flake already provides
                packages.default and checks, or is the project itself (nixosConfigurations,
                homeConfigurations or darwinConfigurations, with no language lockfile)

Options:
  --name NAME       herdr workspace label and agent name prefix (default: the repo directory,
                    sanitized)
  --prefix PREFIX   beads issue prefix for `bd init` (default: bd's, the directory name)
  --tools LIST      openspec agent tools (default: claude,codex,opencode)
  --bootstrap       create the bootstrap epic even if the project looks new or already
                    builds with nix
  --no-bootstrap    never create the bootstrap epic
  -h, --help        show this help
EOF
}

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
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "--name must match [a-z][a-z0-9_-]{0,31} (it labels the herdr workspace)"

# An existing project has files beyond what devflake and the tools it runs create. Decided before
# any of them are written.
scaffold_re='^$|^(\.gitignore|\.envrc|flake\.(nix|lock)|result.*|README[^/]*|LICENSE[^/]*|AGENTS\.md|CLAUDE\.md|\.beads\.gate\.lock)$|^(\.beads|\.claude|\.codex|\.cursor|\.agents|\.opencode|\.herdr|\.direnv|openspec)/'
project_files="$(git ls-files --cached --others --exclude-standard | grep -vE "$scaffold_re" || true)"
existing=0
[[ -z "$project_files" ]] || existing=1
had_flake=0
[[ ! -e flake.nix ]] || had_flake=1

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

  devShells.\${system}.default = inputs.devflake.lib.mkShell {
    inherit pkgs;
    name = "$name";
    packages = [ /* the toolchain your current devShell provides */ ];
    # inputsFrom, env vars and shellHook are passed through to pkgs.mkShell
  };

  # \`inputs\` is the outputs function's argument set (\`{ self, nixpkgs, ... } @ inputs:\`),
  # so this works whether or not the flake destructures its inputs. Inside flake-utils'
  # eachDefaultSystem, write \`devShells.default\` instead. mkShell reads only pkgs and
  # pkgs.stdenv.hostPlatform.system, so pass the per-system pkgs the flake already builds:
  # its nixpkgs config (overlays, allowUnfree) does not matter here, since the agent tools
  # come from devflake's own pkgs.

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
ensure_gitignore

# --- openspec
if [[ ! -d openspec ]]; then
  note "initializing openspec for $tools"
  openspec init --tools "$tools" --no-animation </dev/null
else
  note "openspec already initialized"
fi

# --- skills (devflake-managed: overwritten on every run)
install_skills

# --- AGENTS.md / CLAUDE.md devflake block
upsert_agents_block

# --- bootstrap epic
# bead NAME [BD_CREATE_ARGS...]: create a bead from share/bootstrap/NAME.md (# title, then body)
bead() {
  local f="$share/bootstrap/$1.md"
  shift
  bd create "$(head -n1 "$f" | sed 's/^# *//')" -d "$(tail -n +2 "$f")" --silent "$@"
}
# nix_build_status: why the project's flake needs no bootstrap epic, or nothing when it may.
# The epic's beads bring a project wrapped by nix into the flake, so they are stale for one whose
# flake already provides packages.default and checks, and have no referent for one where nix is
# the project (a NixOS, home-manager or darwin configuration). Either half of the second test
# alone misreads: a Go project may ship a configuration, and a nix-native repo may vendor a
# derivation with its own Cargo.lock below the root.
nix_build_status() {
  ((had_flake)) && command -v nix >/dev/null || return 0
  local probe
  # shellcheck disable=SC2016 # a nix expression, not shell
  probe='root: let
    f = builtins.getFlake root;
    s = builtins.currentSystem;
    has = n: f ? ${n};
  in {
    default = has "packages" && f.packages ? ${s} && f.packages.${s} ? default;
    checks = has "checks" && f.checks ? ${s} && f.checks.${s} != { };
    configs = builtins.filter has [ "nixosConfigurations" "homeConfigurations" "darwinConfigurations" ];
  }'
  note "checking what the existing flake builds (nix eval)" >&2
  local out
  if ! out="$(nix --extra-experimental-features 'nix-command flakes' eval --impure --json \
    --expr "($probe) \"git+file://$root\"" 2>/dev/null)"; then
    note "could not evaluate flake.nix; treating the project as not yet built with nix" >&2
    return 0
  fi
  if [[ "$(jq -r '.default and .checks' <<<"$out")" == true ]]; then
    echo "already builds with nix (packages.default, checks)"
    return 0
  fi
  local configs lockfile_re='^(go\.mod|Cargo\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|uv\.lock|poetry\.lock|requirements[^/]*\.txt|pom\.xml|build\.gradle(\.kts)?)$'
  configs="$(jq -r '.configs | join(", ")' <<<"$out")"
  # Not grep -q on the pipe: under pipefail, git's SIGPIPE would read as no lockfile found
  if [[ -n "$configs" ]] && ! grep -E "$lockfile_re" <<<"$project_files" >/dev/null; then
    echo "is itself nix ($configs, and no language lockfile at its root)"
  fi
}

epic=""
if [[ "$bootstrap" == auto && "$existing" == 1 ]]; then
  nix_status="$(nix_build_status)"
  if [[ -n "$nix_status" ]]; then
    note "this project $nix_status; no bootstrap epic. Pass --bootstrap to create one anyway."
    bootstrap=no
  fi
fi
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
  2. Enter the devshell: \`direnv allow\` or \`nix develop\`. This gives the project a workspace
     '$name' in the shared herdr session, with the parade (mg), captain (claude) and beads (bdi)
     tabs; attach with \`herdr\`.
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

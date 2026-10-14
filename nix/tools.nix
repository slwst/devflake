# The per-project herdr tooling. `name` is the project: the label of its herdr workspace, the
# prefix its agents are named with, and the project beady-eye is told about. `session` is the
# herdr session that workspace lives in, shared with every other devflake project by default.
# `pkgs` is devflake's own package set (with the herdr, beady-eye, mardi-gras overlays).
{
  pkgs,
  name,
  session,
  share,
}:

let
  inherit (pkgs) lib;

  # The herdr session, as every script and the shell hook resolve it. One session shared by all of
  # the host's devflake projects is herdr's own model -- "use one workspace per repo [...] use
  # named sessions when you need completely separate panes, sockets, and persisted runtime state"
  # -- so a single `herdr` shows every project, each as its own workspace. A project that needs
  # that separation sets DEVFLAKE_HERDR_SESSION in its .envrc, or `session` in devflake.lib.mkShell;
  # the reason to is isolation, since herdr scopes nothing within a session and agents have the
  # herdr CLI, so an agent can read and drive any pane of any project sharing the session.
  herdrSession = ''"''${DEVFLAKE_HERDR_SESSION:-${session}}"'';

  # Shell PIDs holding the herdr session open; the server stops when the last one exits. Keyed on
  # the session, so in the shared one a holder from any project keeps it up.
  herdrHoldersDir = ''"''${XDG_RUNTIME_DIR:-/tmp}/herdr-$HERDR_SESSION-$(id -u)/holders"'';

  # The captain's built-in briefing, with the project name filled in
  captainBriefing = pkgs.writeText "${name}-captain.md" (
    builtins.replaceStrings [ "@project@" ] [ name ] (builtins.readFile "${share}/captain.md")
  );

  # Runs claude for the captain tab with devflake's briefing, then the project's .herdr/captain.md
  # (if any), appended to its system prompt. Resumes the last conversation started from the project
  # root (sessions are kept per directory, so never an agent's worktree session) and starts a fresh
  # one when there is none, or with --new.
  # Usage: herdr-captain [--new] <project-root>
  herdr-captain = pkgs.writeShellApplication {
    name = "herdr-captain";
    runtimeInputs = [ pkgs.claude-code ];
    text = ''
      new=0
      if [[ "''${1:-}" == --new ]]; then
        new=1
        shift
      fi
      cd "$1"
      briefing="$(<${captainBriefing})"
      if [[ -r .herdr/captain.md ]]; then
        briefing+=$'\n\n'"$(<.herdr/captain.md)"
      fi
      args=(--append-system-prompt "$briefing")
      if ((new)); then
        claude "''${args[@]}"
      else
        claude --continue "''${args[@]}" || claude "''${args[@]}"
      fi
    '';
  };

  # Starts the headless herdr server if needed and ensures the project workspace exists.
  # Usage: herdr-up [project-root] [holder-pid]   (root defaults to the main checkout of the cwd's repo)
  herdr-up = pkgs.writeShellApplication {
    name = "herdr-up";
    runtimeInputs =
      with pkgs;
      [
        coreutils
        git
        herdr
        jq
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        getent
        util-linux
      ];
    text = ''
      root="''${1:-}"
      holder="''${2:-}"
      if [[ -z "$root" ]]; then
        # Main checkout root, even when run from an agent worktree
        common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
          { echo "herdr-up: not inside a git repository; pass the project root" >&2; exit 1; }
        root="$(dirname "$common")"
      fi
      export HERDR_SESSION=${herdrSession}

      running() {
        herdr session list --json 2>/dev/null \
          | jq -e --arg s "$HERDR_SESSION" '.sessions[] | select(.name == $s and .running)' >/dev/null
      }

      if [[ -n "$holder" ]]; then
        mkdir -p ${herdrHoldersDir}
        touch ${herdrHoldersDir}/"$holder"
      fi

      if ! running; then
        # Detach fully so the server outlives this shell. It must not inherit any of the caller's
        # fds: nix-direnv waits on a pipe for EOF, and nix passes down its sleep-inhibit lock.
        (
          for fd in /dev/fd/*; do
            fd="''${fd##*/}"
            if ((fd > 2)); then eval "exec $fd>&-"; fi
          done 2>/dev/null
          # Nor any of the caller's direnv state. When direnv starts the server (this runs from
          # inside the root .envrc), the server and every pane and agent under it would otherwise
          # inherit DIRENV_DIR and DIRENV_DIFF naming the repo root: a pane's own direnv hook then
          # sees a diff for a directory it is not in and unloads it. Unset inside this subshell
          # only -- the shellHook above still needs DIRENV_IN_ENVRC to tell a direnv load (no exit
          # hook, so no herdr-down) from an interactive nix develop.
          unset DIRENV_DIR DIRENV_DIFF DIRENV_FILE DIRENV_WATCHES DIRENV_IN_ENVRC
          # Nor the devshell's scratch directory. nix develop points TMPDIR (and NIX_BUILD_TOP) at a
          # /tmp/nix-shell.* directory that is removed when that shell exits or direnv reloads; the
          # server outlives it, so its panes and agents would be left with a TMPDIR that no longer
          # exists and mktemp fails. Fall back to /tmp like any other long-lived daemon.
          unset TMPDIR TMP TEMP TEMPDIR NIX_BUILD_TOP
          cd "$root"
          # Panes run $SHELL, which the devshell has replaced with stdenv's bash; use the login shell
          if [[ -n "''${DEVFLAKE_HERDR_SHELL:-}" ]]; then
            SHELL="$DEVFLAKE_HERDR_SHELL"
          elif command -v getent >/dev/null; then
            SHELL="$(getent passwd "$(id -un)" | cut -d: -f7)"
          elif [[ -x /usr/bin/dscl ]]; then
            SHELL="$(/usr/bin/dscl . -read "/Users/$(id -un)" UserShell | cut -d' ' -f2)"
          fi
          export SHELL="''${SHELL:-/bin/sh}"
          if command -v setsid >/dev/null; then
            setsid -f herdr server </dev/null >/dev/null 2>&1
          else
            nohup herdr server </dev/null >/dev/null 2>&1 &
          fi
        )
        for _ in $(seq 50); do
          running && break
          sleep 0.1
        done
        if ! running; then
          echo "herdr: server for session '$HERDR_SESSION' failed to start" >&2
          exit 1
        fi
      fi

      # A stopped server restores its saved workspaces, so only create the workspace when missing.
      # Found through the repository, not by label: the session holds every project, and two of
      # them can be called the same thing. Not through a workspace's own .worktree either -- the
      # server only fills that in while an attached client asks the sidebar for git status.
      ws="$(herdr worktree list --cwd "$root" 2>/dev/null |
        jq -r --arg root "$root" '[.result.worktrees[]? | select(.path == $root)][0].open_workspace_id // empty')"
      if [[ -z "$ws" ]]; then
        ws="$(herdr workspace create --cwd "$root" --label ${name} --no-focus |
          jq -r '.result.workspace.workspace_id')"
      fi

      # Ensures a tab labelled $1 whose pane runs $3, a process named $2, and leaves its pane in $pane.
      # A restored tab comes back as a bare shell, so start it whenever it is not running.
      tab_running() {
        local label="$1" proc="$2" cmd="$3"
        pane="$(herdr pane list --workspace "$ws" |
          jq -r --arg t "$(herdr tab list --workspace "$ws" |
            jq -r --arg l "$label" '[.result.tabs[] | select(.label == $l)][0].tab_id // empty')" \
            '[.result.panes[] | select(.tab_id == $t)][0].pane_id // empty')"
        if [[ -z "$pane" ]]; then
          pane="$(herdr tab create --workspace "$ws" --cwd "$root" --label "$label" --no-focus |
            jq -r '.result.root_pane.pane_id')"
        fi
        if ! herdr pane process-info --pane "$pane" |
          jq -e --arg p "$proc" '.result.process_info.foreground_processes[] | select(.name == $p)' >/dev/null; then
          herdr pane run "$pane" "$cmd" >/dev/null
        fi
      }

      # Tabs are listed in creation order (herdr cannot move them): parade, captain, beads.
      # A restored workspace keeps the order it was saved with.
      # mardi-gras in a "parade" tab: the beads as a parade of rolling, lined up, stalled, and closed
      tab_running parade mg "${pkgs.mardi-gras}/bin/mg"
      # claude briefed on the agent tooling in a "captain" tab, who runs the parade; nix's
      # wrapper leaves the real binary as .claude-unwrapped, which the kernel truncates to 15 characters
      if [[ "''${DEVFLAKE_CAPTAIN:-1}" != 0 ]]; then
        # DEVFLAKE_CAPTAIN_NEW=1 starts a new conversation instead of resuming, when the tab
        # (re)starts claude; a claude that is still running is left alone
        captain=("${herdr-captain}/bin/herdr-captain")
        [[ "''${DEVFLAKE_CAPTAIN_NEW:-0}" == 0 ]] || captain+=(--new)
        tab_running captain .claude-unwrapp "$(printf '%q ' "''${captain[@]}" "$root")"
        # Name the pane in beady-eye, which otherwise lists it with no agent (it holds no bead)
        herdr pane report-metadata "$pane" --source herdr:claude --display-agent captain \
          --title captain >/dev/null || true
      fi
      # beady-eye in a "beads" tab: bead trees with each claiming agent's pane beside its bead
      tab_running beads bdi "${pkgs.beady-eye}/bin/bdi"

      echo "herdr: workspace '${name}' in session '$HERDR_SESSION' (attach with: herdr)"
    '';
  };

  # Takes the project out of the herdr session, and stops the server once nothing is left in it.
  # Usage: herdr-down [--all] [project-root] [holder-pid]   (root defaults to the cwd's repo)
  # With a holder pid it does nothing while another devshell still holds the session. Otherwise it
  # closes this repository's workspaces -- the project's tabs and any agents in them -- and stops
  # the server only once no other project's workspace is left. --all stops it regardless.
  herdr-down = pkgs.writeShellApplication {
    name = "herdr-down";
    runtimeInputs = with pkgs; [
      coreutils
      git
      herdr
      jq
    ];
    text = ''
      export HERDR_SESSION=${herdrSession}
      holders=${herdrHoldersDir}

      all=0
      if [[ "''${1:-}" == --all ]]; then
        all=1
        shift
      fi
      root="''${1:-}"
      holder="''${2:-}"

      [[ -z "$holder" ]] || rm -f "$holders/$holder"

      stop_server() {
        rm -rf "$holders"
        herdr server stop >/dev/null 2>&1 || true
      }

      if ((all)); then
        stop_server
        exit 0
      fi

      # Any holder still alive keeps the session up; drop the ones that are not
      for f in "$holders"/*; do
        [[ -e "$f" ]] || continue
        if kill -0 "$(basename "$f")" 2>/dev/null; then
          exit 0
        fi
        rm -f "$f"
      done

      herdr session list --json 2>/dev/null |
        jq -e --arg s "$HERDR_SESSION" '.sessions[] | select(.name == $s and .running)' >/dev/null ||
        exit 0

      if [[ -z "$root" ]]; then
        common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
          { echo "herdr-down: not inside a git repository; pass the project root, or --all" >&2; exit 1; }
        root="$(dirname "$common")"
      fi

      # Every workspace open on this repository: the project's, and one per agent worktree.
      # Closed, not saved -- a stopped server restores its workspaces, but their tabs come back as
      # bare shells that the next `herdr-up` restarts anyway, and the captain resumes its
      # conversation from the project root whichever way round it goes.
      while read -r ws; do
        [[ -n "$ws" ]] || continue
        herdr workspace close "$ws" >/dev/null 2>&1 || true
      done < <(herdr worktree list --cwd "$root" 2>/dev/null |
        jq -r '.result.worktrees[]?.open_workspace_id // empty')

      # Nothing any other project put there is left
      if [[ "$(herdr workspace list | jq '.result.workspaces | length')" == 0 ]]; then
        stop_server
      fi
    '';
  };

  # Spawns/lists/removes agents, each in its own worktree under .worktrees/ and herdr workspace
  herdr-agents = pkgs.writeShellApplication {
    name = "herdr-agents";
    runtimeInputs = with pkgs; [
      beads
      coreutils
      findutils # find -printf (BSD find lacks it)
      git
      gnugrep
      gnused
      herdr
      herdr-up
      jq
      socat
      util-linux # column, flock, setsid
    ];
    text = ''
      export HERDR_SESSION=${herdrSession}
      project=${name}
      builtin_presets=${share}/prompts
      ${builtins.readFile ./herdr-agents.sh}
    '';
  };

  # Sourced by the devshell: points herdr at the project session and manages the server's lifetime
  shellHook = ''
    export DEVFLAKE_PROJECT=${name}
    export DEVFLAKE_SHARE=${share}

    # Point herdr at the session the project's workspace lives in, unless already inside a pane
    # of some herdr session
    if [[ -z "''${HERDR_PANE_ID:-}" ]]; then
      export HERDR_SESSION=${herdrSession}
    fi

    if [[ ! -d .beads && -z "''${HERDR_PANE_ID:-}" ]]; then
      echo "devflake: no .beads/ here yet; run \`devflake-init\` to set up beads, openspec and the agent config" >&2
    fi

    # Manage the server only for interactive shells and direnv (not `nix develop --command`), never
    # inside a herdr pane (stopping the server would kill the pane), and not with DEVFLAKE_HERDR=0.
    if [[ ($- == *i* || -n "''${DIRENV_IN_ENVRC:-}") && -z "''${HERDR_PANE_ID:-}" && "''${DEVFLAKE_HERDR:-1}" != 0 ]]; then
      # Main checkout root, even when entered from an agent worktree
      _devflake_root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")"
      [[ "$_devflake_root" != . ]] || _devflake_root="$PWD"
      if [[ -n "''${DIRENV_IN_ENVRC:-}" ]]; then
        # direnv has no unload hook; the server keeps running until `herdr-down`
        herdr-up "$_devflake_root"
      else
        herdr-up "$_devflake_root" $$ && trap "herdr-down ''${_devflake_root@Q} $$" EXIT
      fi
      unset _devflake_root
    fi
  '';
in
{
  inherit
    herdr-agents
    herdr-captain
    herdr-down
    herdr-up
    shellHook
    ;
  packages = [
    herdr-agents
    herdr-captain
    herdr-down
    herdr-up
  ];
}

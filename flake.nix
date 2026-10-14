{
  description = "devflake -- an agentic dev environment (herdr, beads, openspec, coding agents) for any project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    openspec.url = "github:Fission-AI/OpenSpec";
    openspec.inputs.nixpkgs.follows = "nixpkgs";
    claude-code.url = "github:sadjow/claude-code-nix";
    beady-eye.url = "github:CodeForBreakfast/beady-eye/v0.23.0";
    mardi-gras.url = "github:slwst/mardi-gras/feat/flake-refactor";
    # herdr's package needs zig_0_16, which our pinned nixpkgs lacks, so it keeps its own nixpkgs
    herdr.url = "github:herdrdev/herdr/v0.9.3";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      openspec,
      claude-code,
      beady-eye,
      mardi-gras,
      herdr,
    }:
    let
      inherit (nixpkgs) lib;

      # Built-in captain briefing, prompt presets, bootstrap beads, skills and docs
      share = ./share;

      # devflake's own package set. The agent tooling is always built from it, so its versions are
      # pinned by this flake's lock rather than by each project's nixpkgs.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];
          overlays = [
            openspec.overlays.default
            claude-code.overlays.default
            beady-eye.overlays.default
            # Three of beady-eye's tests fail on darwin (upstream CI is Linux-only), none in a way that matters here:
            # - Two watcher tests: macOS refuses setsockopt (EINVAL) on a socket whose peer has closed, so
            #   `next()` in src/collect/watched.rs drops lines still buffered when the watcher hangs up.
            #   bdi then reads those trackers itself, which is its fallback anyway.
            # - The project-supplied direnv test passes its assertions, then its cleanup races the direnv
            #   shim, which is still writing its log into the directory being removed.
            # Crane bakes the test command into checkPhase, so the skips replace it.
            (
              _final: prev:
              lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
                beady-eye = prev.beady-eye.overrideAttrs {
                  checkPhase = ''
                    runHook preCheck
                    cargoWithProfile test --locked -- \
                      --skip collect::watched::tests::a_run_that_stays_reads_for_itself_once_its_watcher_goes \
                      --skip collect::watched::tests::a_watcher_that_goes_part_way_leaves_the_rest_to_be_read_for_itself \
                      --skip a_direnv_the_project_supplies_is_found_from_the_projects_own_directory
                    runHook postCheck
                  '';
                };
              }
            )
            mardi-gras.overlays.default
            (final: _prev: { herdr = herdr.packages.${final.stdenv.hostPlatform.system}.default; })
          ];
        };

      # herdr session and workspace names: [a-z][a-z0-9_-], at most 32 characters
      checkName =
        name:
        if builtins.match "[a-z][a-z0-9_-]{0,31}" name != null then
          name
        else
          throw "devflake: name '${name}' must match [a-z][a-z0-9_-]{0,31} (it names the herdr session)";

      mkTools =
        system: name:
        import ./nix/tools.nix {
          pkgs = pkgsFor system;
          name = checkName name;
          inherit share;
        };

      # The tools every devflake shell carries, regardless of the project's language
      # (explicit `p.`: `with p;` would lose to the flake inputs of the same names)
      basePackages = p: [
        p.beads
        p.beady-eye
        p.claude-code
        p.herdr
        p.mardi-gras
        p.openspec
        p.opencode
      ];

      mkInit =
        p:
        p.writeShellApplication {
          name = "devflake-init";
          runtimeInputs = [
            p.beads
            p.coreutils
            p.git
            p.gnugrep
            p.gnused
            p.jq
            p.openspec
          ];
          text = ''
            share=${share}
            template_dir=${./templates/default}
            ${builtins.readFile ./nix/devflake-init.sh}
          '';
        };
    in
    {
      lib = {
        # A devshell with the agent tooling plus the project's own packages.
        #
        #   devShells.default = devflake.lib.mkShell {
        #     inherit pkgs;            # the project's nixpkgs (provides mkShell)
        #     name = "my-project";     # herdr session/workspace name
        #     packages = [ pkgs.go ];  # the project's toolchain
        #   };
        #
        # Any other attribute (inputsFrom, env vars, ...) is passed to pkgs.mkShell; shellHook runs
        # after devflake's.
        mkShell =
          {
            pkgs,
            name,
            packages ? [ ],
            shellHook ? "",
            ...
          }@args:
          let
            system = pkgs.stdenv.hostPlatform.system;
            p = pkgsFor system;
            tools = mkTools system name;
          in
          pkgs.mkShell (
            removeAttrs args [
              "pkgs"
              "name"
              "packages"
              "shellHook"
            ]
            // {
              name = "${name}-devshell";
              packages = basePackages p ++ tools.packages ++ [ (mkInit p) ] ++ packages;
              shellHook = tools.shellHook + shellHook;
            }
          );
      };

      templates.default = {
        path = ./templates/default;
        description = "A project using devflake's agentic devshell";
        welcomeText = ''
          Created flake.nix and .envrc. Next, from the project root:

            nix develop --command devflake-init

          which sets the project name, initializes beads and openspec, and (for an existing
          project) creates the bootstrap epic that brings the build and tests into the flake.
        '';
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        p = pkgsFor system;
        init = mkInit p;
        tools = mkTools system "devflake";
      in
      {
        packages = {
          default = init;
          inherit init;
          inherit (p)
            beads
            beady-eye
            claude-code
            herdr
            mardi-gras
            openspec
            opencode
            ;
        };

        # writeShellApplication runs shellcheck on each script while building it
        checks = {
          inherit init;
          inherit (tools)
            herdr-agents
            herdr-captain
            herdr-down
            herdr-up
            ;

          # `nix fmt` (nixfmt-tree) formats the .nix files and leaves everything else alone, so
          # checking those is the same gate. The source is filtered to them, which keeps a doc or
          # script edit from rebuilding this check.
          fmt =
            p.runCommand "devflake-fmt-check"
              {
                src = lib.fileset.toSource {
                  root = ./.;
                  fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
                };
                nativeBuildInputs = [ p.nixfmt ];
              }
              ''
                cd "$src"
                # Guard against an empty file list, which would make this check vacuous
                test "$(find . -name '*.nix' | wc -l)" -gt 0 || {
                  echo "fmt: no .nix files in the filtered source" >&2
                  exit 1
                }
                # --check names the files it would reformat and changes nothing
                find . -name '*.nix' -exec nixfmt --check {} + || {
                  echo "run 'nix fmt' to format them" >&2
                  exit 1
                }
                touch "$out"
              '';
        };

        # devflake's own devshell is a devflake shell
        devShells.default = self.lib.mkShell {
          pkgs = p;
          name = "devflake";
          packages = [ p.nixfmt ];
        };

        formatter = p.nixfmt-tree;
      }
    );
}

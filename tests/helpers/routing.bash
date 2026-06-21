# tests/helpers/routing.bash — declarative e2e routing scenarios for `envs`.
#
# A scenario is three strings: the .env contents, the routing config, and an
# indented directory tree. The helper realizes them under an isolated tmp HOME
# (+ $ENVS_CONFIG_DIR), so a @test reads like the scenario it describes:
#
#   routing_case "TEST=true" "<current_dir:frontends>test:.env" "
#     - ~
#       - Dev
#         - frontends
#       - frontends
#   "
#   assert_var Dev/frontends test TEST true
#   assert_var frontends     test TEST true
#
# The `envs` banner goes to stderr; assert_var captures stdout only, so the
# asserted value is exactly what the command saw. Config is injected via
# $ENVS_CONFIG_DIR (the binary reads $ENVS_CONFIG_DIR/config — src/main.zig),
# so no user dotfiles are touched.

# Set $ENVS_BIN to the built binary. The e2e suite must FAIL (not skip) when a
# dependency is missing — it runs locally and in CI, where "binary not built"
# means "set it up", not "silently pass". We deliberately do NOT auto-download
# Zig the way install.sh does; just say what to install.
routing_require_bin() {
  local repo
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ENVS_BIN="$repo/zig-out/bin/envs"
  export ENVS_BIN
  if [ ! -x "$ENVS_BIN" ]; then
    echo "FATAL: envs binary not built at $ENVS_BIN" >&2
    echo "  Install Zig 0.16+ and run 'zig build' before the e2e suite." >&2
    return 1
  fi
}

# git-context tests need a real git. Fail (don't skip) when it's absent.
routing_require_git() {
  if ! command -v git >/dev/null 2>&1; then
    echo "FATAL: git not found on PATH — install git to run the git-context e2e." >&2
    return 1
  fi
}

# git_repo <reldir> <origin-url> <branch> — a real git repo under $HOME. No
# commit needed: symbolic-ref sets HEAD's branch, and envs reads .git/HEAD +
# .git/config directly (src/context.zig), so this is enough for repo/org/branch.
git_repo() {
  local dir="$HOME/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$2"
  git -C "$dir" symbolic-ref HEAD "refs/heads/$3"
}

# git_worktree <main-reldir> <wt-reldir> <branch> <origin-url> — a real linked
# worktree via `git worktree add`, so envs sees git's actual worktree layout
# (.git file -> gitdir, commondir -> main repo's config). Uses a real commit
# because `worktree add` requires one.
git_worktree() {
  local main="$HOME/$1" wt="$HOME/$2"
  mkdir -p "$main" "$(dirname "$wt")"
  git -C "$main" init -q
  git -C "$main" remote add origin "$4"
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$main" -c user.email=t@t -c user.name=t worktree add -q -b "$3" "$wt"
}

# routing_case <env_contents> <config_contents> <tree>
routing_case() {
  ROUTE_TMP="$(mktemp -d -t envs-routing.XXXXXX)"
  export ROUTE_TMP
  export HOME="$ROUTE_TMP"

  ENVS_CONFIG_DIR="$ROUTE_TMP/config"
  mkdir -p "$ENVS_CONFIG_DIR"
  export ENVS_CONFIG_DIR

  printf '%s\n' "$1" > "$ENVS_CONFIG_DIR/.env"
  printf '%s\n' "$2" > "$ENVS_CONFIG_DIR/config"
  _routing_realize_tree "$3"
}

# Write an extra file under $ENVS_CONFIG_DIR (for multi-.env scenarios), e.g.
#   cfg_file .env.dev "TEST=devval"
#   cfg_file frontends/.env "TEST=interp"
cfg_file() {
  mkdir -p "$ENVS_CONFIG_DIR/$(dirname "$1")"
  printf '%s\n' "$2" > "$ENVS_CONFIG_DIR/$1"
}

# Run `envs <env_name> ...` from $HOME/<reldir>, then assert that the injected
# variable <var> equals <expected> (empty string means "no rule matched").
assert_var() {
  local dir="$1" name="$2" var="$3" expected="$4" got
  got="$( cd "$HOME/$dir" && "$ENVS_BIN" "$name" sh -c "printf '%s' \"\$$var\"" 2>/dev/null )"
  if [ "$got" != "$expected" ]; then
    echo "assert_var FAIL @ '$dir' (envs $name -> \$$var)" >&2
    echo "  expected: [$expected]" >&2
    echo "  got:      [$got]" >&2
    return 1
  fi
}

routing_teardown() {
  if [ -n "${ROUTE_TMP:-}" ] && [ -d "$ROUTE_TMP" ]; then
    case "$ROUTE_TMP" in
      /tmp/*|/var/folders/*|/private/var/folders/*) rm -rf "$ROUTE_TMP" ;;
    esac
  fi
}

# Indented `- name` tree -> real dirs under $HOME. `~` is the root; each level
# is 2 more spaces of indent. The whole block is dedented first, so the tree may
# be indented to match the surrounding test code.
_routing_realize_tree() {
  local tree="$1" line lead content depth i path
  local min=9999 stripped

  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    [ -z "$stripped" ] && continue
    lead="${line%%[![:space:]]*}"
    [ "${#lead}" -lt "$min" ] && min=${#lead}
  done <<EOF
$tree
EOF
  [ "$min" -eq 9999 ] && min=0

  local -a stack=()
  while IFS= read -r line; do
    lead="${line%%[![:space:]]*}"
    content="${line:${#lead}}"
    [ -z "$content" ] && continue
    depth=$(( (${#lead} - min) / 2 ))
    content="${content#- }"
    content="${content#-}"
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"
    [ -z "$content" ] && continue
    if [ "$content" = "~" ]; then
      stack=()
      continue
    fi
    stack[$((depth - 1))]="$content"
    for (( i = depth; i < ${#stack[@]}; i++ )); do unset 'stack[i]'; done
    path="$HOME"
    for (( i = 0; i < depth; i++ )); do path="$path/${stack[i]}"; done
    mkdir -p "$path"
  done <<EOF
$tree
EOF
}

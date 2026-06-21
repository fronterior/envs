#!/usr/bin/env bats
# tests/envs-routing.bats — end-to-end routing for the `envs <name> <cmd>` binary.
#
# Proves the headline path the rest of the suite never exercises: match a rule ->
# load its .env -> exec the command with those vars injected. Uses the REAL
# compiled binary against REAL directories under a tmpdir.
#
# Focus: `<current_dir:foo>` with no '*' is a *substring* match against the
# absolute cwd path, and matching is ASCII case-insensitive. The condition here
# is a multi-segment substring `dev/frontends` (lowercase) — so:
#   * `.../Dev/frontends` matches (substring present, case-insensitive)
#   * `.../frontends`     does NOT (no `dev/frontends` substring)
# The second dir is the negative case: the substring distinguishes the two,
# which is what makes this a substring proof rather than a match-anything one.
#
# Isolation: config is injected via $ENVS_CONFIG_DIR (the binary reads
# $ENVS_CONFIG_DIR/config — src/main.zig), so no user dotfiles are touched.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ENVS_BIN="$REPO_ROOT/zig-out/bin/envs"
  if [ ! -x "$ENVS_BIN" ]; then
    skip "zig-out/bin/envs not built; run 'zig build' first"
  fi
  export ENVS_BIN

  ROUTE_TMP="$(mktemp -d -t envs-routing.XXXXXX)"
  export ROUTE_TMP
  export HOME="$ROUTE_TMP"

  _cfg="$ROUTE_TMP/config-dir"
  mkdir -p "$_cfg"
  export ENVS_CONFIG_DIR="$_cfg"

  printf 'TEST=true\n' > "$ROUTE_TMP/shared.env"

  # Real tree. `Dev/frontends` (capital D) is the matching path; bare `frontends`
  # is the negative — it has no `dev/frontends` substring.
  mkdir -p "$ROUTE_TMP/Dev/frontends" "$ROUTE_TMP/frontends"

  # Lowercase, multi-segment substring. Exercises both the substring rule and
  # case-insensitive matching at once.
  printf '<current_dir:dev/frontends>test:%s\n' "$ROUTE_TMP/shared.env" > "$_cfg/config"
}

teardown() {
  if [ -n "${ROUTE_TMP:-}" ] && [ -d "$ROUTE_TMP" ]; then
    case "$ROUTE_TMP" in
      /tmp/*|/var/folders/*|/private/var/folders/*) rm -rf "$ROUTE_TMP" ;;
    esac
  fi
}

# Single quotes around the sh body: the parent (bats) shell must NOT expand
# $TEST — the inner sh, spawned by envs with the injected env, expands it.
@test "current_dir 'dev/frontends' matches '.../Dev/frontends' (substring + case-insensitive) -> injects TEST" {
  cd "$ROUTE_TMP/Dev/frontends"
  run "$ENVS_BIN" test sh -c 'printf "TESTVAL=[%s]" "$TEST"'
  [ "$status" -eq 0 ] || { echo "exit=$status"; echo "$output"; return 1; }
  [[ "$output" == *"TESTVAL=[true]"* ]] || { echo "expected TESTVAL=[true]:"; echo "$output"; return 1; }
}

@test "current_dir 'dev/frontends' does NOT match '.../frontends' (no substring) -> no injection, command still runs" {
  cd "$ROUTE_TMP/frontends"
  run "$ENVS_BIN" test sh -c 'printf "TESTVAL=[%s]" "$TEST"'
  [ "$status" -eq 0 ] || { echo "exit=$status"; echo "$output"; return 1; }
  [[ "$output" == *"TESTVAL=[]"* ]] || { echo "expected empty TESTVAL=[]:"; echo "$output"; return 1; }
}

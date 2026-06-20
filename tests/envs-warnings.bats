#!/usr/bin/env bats
# tests/envs-warnings.bats — normal-mode diagnostics for the `envs` binary.
#
# Covers the unsupported-`current_dir`-wildcard warning: patterns that use `*`
# in a position the matcher does not interpret silently fall back to a literal
# substring (which can never match a real path). Normal mode warns about them on
# stderr; source mode stays silent (it runs on every shell prompt).

load helpers/isolate

bats_require_minimum_version 1.5.0

setup() {
  isolate_setup
}

teardown() {
  isolate_teardown
}

# Overwrite the isolate config with one unsupported + one supported rule.
write_warn_config() {
  cat > "$ENVS_CONFIG_DIR/config" <<EOF
<current_dir:a/*/b>dev:$ENVS_CONFIG_DIR/.env.dev
<current_dir:*/sampleapp-dev>dev:$ENVS_CONFIG_DIR/.env.dev
EOF
}

@test "normal mode: warns on unsupported current_dir wildcard pattern (stderr)" {
  write_warn_config
  cd "$REPO_DIR_OTHER"
  run --separate-stderr env HOME="$ISOLATED_HOME" ENVS_CONFIG_DIR="$ENVS_CONFIG_DIR" \
    "$BIN_DIR/envs" someenv true
  [[ "$stderr" == *"unsupported current_dir pattern: a/*/b"* ]]
}

@test "normal mode: does not warn on supported current_dir patterns" {
  cat > "$ENVS_CONFIG_DIR/config" <<EOF
<current_dir:*/sampleapp-dev>dev:$ENVS_CONFIG_DIR/.env.dev
<current_dir:bare>dev:$ENVS_CONFIG_DIR/.env.dev
EOF
  cd "$REPO_DIR_OTHER"
  run --separate-stderr env HOME="$ISOLATED_HOME" ENVS_CONFIG_DIR="$ENVS_CONFIG_DIR" \
    "$BIN_DIR/envs" someenv true
  [[ "$stderr" != *"unsupported current_dir pattern"* ]]
}

@test "source mode: suppresses unsupported-pattern warning (clean stderr)" {
  write_warn_config
  cd "$REPO_DIR_OTHER"
  run --separate-stderr env HOME="$ISOLATED_HOME" ENVS_CONFIG_DIR="$ENVS_CONFIG_DIR" \
    "$BIN_DIR/envs" --source-match someenv
  [[ "$stderr" != *"unsupported current_dir pattern"* ]]
  [ -z "$stderr" ]
}

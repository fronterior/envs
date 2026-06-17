#!/usr/bin/env bats
# tests/uninstall.bats — cases for uninstall.sh (zig-era + sh-era + mixed).
#
# Each test builds a fake $HOME under mktemp with a synthetic envs install,
# runs ./uninstall.sh against it via env overrides, then asserts the right
# paths are gone (and ~/.config/envs is preserved by default).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
  export UNINSTALL_SH

  ISOLATED_HOME="$(mktemp -d -t envs-uninstall.XXXXXX)"
  export ISOLATED_HOME
  export HOME="$ISOLATED_HOME"

  # Match install.sh default layout.
  TARGET_DIR="$ISOLATED_HOME/.local/bin"
  LIB_DIR="$ISOLATED_HOME/.local/lib/envs"
  ENVS_HOME_DIR="$ISOLATED_HOME/.local/share/envs"
  ZIG_DIR="$ENVS_HOME_DIR/zig"
  CONFIG_DIR="$ISOLATED_HOME/.config/envs"
  export TARGET_DIR LIB_DIR ENVS_HOME_DIR ZIG_DIR CONFIG_DIR

  mkdir -p "$TARGET_DIR" "$LIB_DIR" "$ENVS_HOME_DIR" "$CONFIG_DIR"
}

teardown() {
  if [ -n "${ISOLATED_HOME:-}" ] && [ -d "$ISOLATED_HOME" ]; then
    case "$ISOLATED_HOME" in
      /tmp/*|/var/folders/*|/private/var/folders/*)
        rm -rf "$ISOLATED_HOME"
        ;;
      *)
        echo "teardown: refusing to rm non-tmp ISOLATED_HOME=$ISOLATED_HOME" >&2
        ;;
    esac
  fi
}

# Run uninstall.sh with our isolated HOME-based path overrides.
run_uninstall() {
  HOME="$ISOLATED_HOME" \
  ENVS_HOME="$ENVS_HOME_DIR" \
  ENVS_LIB_DIR="$LIB_DIR" \
  ENVS_TARGET_DIR="$TARGET_DIR" \
  ENVS_ZIG_DIR="$ZIG_DIR" \
    "$UNINSTALL_SH" "$@"
}

# Fake a "zig-era release install": prod binary at $LIB_DIR/envs,
# prod symlink $TARGET_DIR/envs -> $LIB_DIR/envs, staged release files
# under $ENVS_HOME_DIR, managed zig cache under $ZIG_DIR.
fake_zig_release() {
  # Binary
  printf '#!/bin/sh\necho fake-envs\n' > "$LIB_DIR/envs"
  chmod +x "$LIB_DIR/envs"
  # Symlink
  ln -s "$LIB_DIR/envs" "$TARGET_DIR/envs"
  # Stage files
  for f in envs-source.sh envs-dev-source.sh envs-source.fish README.md; do
    printf '# fake %s\n' "$f" > "$ENVS_HOME_DIR/$f"
  done
  mkdir -p "$ENVS_HOME_DIR/example"
  printf 'fake config\n' > "$ENVS_HOME_DIR/example/config"
  # Managed zig
  mkdir -p "$ZIG_DIR/0.16.0"
  printf '#!/bin/sh\necho fake-zig\n' > "$ZIG_DIR/0.16.0/zig"
  chmod +x "$ZIG_DIR/0.16.0/zig"
}

# Fake a "zig-era dev install": dev wrapper at $TARGET_DIR/envs-dev pointing
# at a fake repo checkout's zig-out/bin/envs.
fake_zig_dev() {
  FAKE_REPO="$ISOLATED_HOME/checkout"
  mkdir -p "$FAKE_REPO/zig-out/bin"
  printf '#!/bin/sh\necho fake-dev-envs\n' > "$FAKE_REPO/zig-out/bin/envs"
  chmod +x "$FAKE_REPO/zig-out/bin/envs"
  ln -s "$FAKE_REPO/zig-out/bin/envs" "$TARGET_DIR/envs-dev"
  export FAKE_REPO
}

# Fake an "old sh-era self-clone install": .git present under $ENVS_HOME_DIR,
# prod symlink -> $ENVS_HOME_DIR/bin/envs (the old sh script).
fake_sh_self_clone() {
  mkdir -p "$ENVS_HOME_DIR/.git" "$ENVS_HOME_DIR/bin"
  printf '#!/bin/sh\necho fake-sh-envs\n' > "$ENVS_HOME_DIR/bin/envs"
  chmod +x "$ENVS_HOME_DIR/bin/envs"
  ln -s "$ENVS_HOME_DIR/bin/envs" "$TARGET_DIR/envs"
}

# Seed ~/.config/envs/config so we can assert preservation.
seed_config() {
  printf 'fake user routing config\n' > "$CONFIG_DIR/config"
  printf 'KEY=value\n' > "$CONFIG_DIR/.env.dev"
}

# ---------------------------------------------------------------------------
# (a) zig-era fresh install
# ---------------------------------------------------------------------------

@test "zig fresh: prod symlink, lib binary, stage files, zig cache all removed" {
  fake_zig_release
  seed_config

  run run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed symlink: $TARGET_DIR/envs"* ]]
  [[ "$output" == *"removed: $LIB_DIR/envs"* ]]
  [[ "$output" == *"removed: $ENVS_HOME_DIR/envs-source.sh"* ]]
  [[ "$output" == *"removed: $ENVS_HOME_DIR/example"* ]]
  [[ "$output" == *"managed zig cache"* ]]

  [ ! -e "$TARGET_DIR/envs" ] && [ ! -L "$TARGET_DIR/envs" ]
  [ ! -e "$LIB_DIR/envs" ]
  [ ! -d "$LIB_DIR" ]
  [ ! -e "$ENVS_HOME_DIR/envs-source.sh" ]
  [ ! -e "$ENVS_HOME_DIR/envs-dev-source.sh" ]
  [ ! -e "$ENVS_HOME_DIR/envs-source.fish" ]
  [ ! -e "$ENVS_HOME_DIR/README.md" ]
  [ ! -d "$ENVS_HOME_DIR/example" ]
  [ ! -d "$ZIG_DIR" ]
}

@test "zig fresh: ~/.config/envs preserved by default" {
  fake_zig_release
  seed_config

  run run_uninstall
  [ "$status" -eq 0 ]
  [ -f "$CONFIG_DIR/config" ]
  [ -f "$CONFIG_DIR/.env.dev" ]
  [[ "$output" == *"\$HOME/.config/envs/ are preserved"* ]]
}

@test "zig fresh: --purge-config removes ~/.config/envs" {
  fake_zig_release
  seed_config

  run run_uninstall --purge-config
  [ "$status" -eq 0 ]
  [ ! -d "$CONFIG_DIR" ]
  [[ "$output" == *"removed: $CONFIG_DIR (--purge-config)"* ]]
}

@test "zig fresh: --keep-zig preserves managed zig cache" {
  fake_zig_release

  run run_uninstall --keep-zig
  [ "$status" -eq 0 ]
  [ -d "$ZIG_DIR" ]
  [ -x "$ZIG_DIR/0.16.0/zig" ]
  [[ "$output" == *"managed zig cache preserved (--keep-zig)"* ]]
}

# ---------------------------------------------------------------------------
# (b) zig-era dev install (envs-dev wrapper only — prod untouched)
# ---------------------------------------------------------------------------

@test "zig dev: envs-dev wrapper removed when target is zig-out/bin/envs" {
  fake_zig_dev

  run run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed symlink: $TARGET_DIR/envs-dev"* ]]
  [ ! -e "$TARGET_DIR/envs-dev" ] && [ ! -L "$TARGET_DIR/envs-dev" ]
  # Fake repo checkout itself MUST NOT be touched.
  [ -x "$FAKE_REPO/zig-out/bin/envs" ]
}

@test "zig dev: unrelated envs-dev symlink target gets WARN (left alone)" {
  # Point envs-dev at something that does NOT match */zig-out/bin/envs.
  OTHER="$ISOLATED_HOME/some-other-bin/envs-dev"
  mkdir -p "$(dirname "$OTHER")"
  printf '#!/bin/sh\necho other\n' > "$OTHER"
  chmod +x "$OTHER"
  ln -s "$OTHER" "$TARGET_DIR/envs-dev"

  run run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: $TARGET_DIR/envs-dev is a symlink to $OTHER (not our dev wrapper)"* ]]
  # Symlink preserved.
  [ -L "$TARGET_DIR/envs-dev" ]
  [ -x "$OTHER" ]
}

# ---------------------------------------------------------------------------
# (c) old sh-era self-clone install (.git present under $_envs_home)
# ---------------------------------------------------------------------------

@test "sh self-clone: prod symlink + entire clone dir removed" {
  fake_sh_self_clone
  seed_config

  run run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed symlink: $TARGET_DIR/envs"* ]]
  [[ "$output" == *"removed clone: $ENVS_HOME_DIR"* ]]
  [ ! -e "$TARGET_DIR/envs" ] && [ ! -L "$TARGET_DIR/envs" ]
  [ ! -d "$ENVS_HOME_DIR" ]
  # Config preserved.
  [ -f "$CONFIG_DIR/config" ]
}

# ---------------------------------------------------------------------------
# (d) mixed: zig-era release + leftover dev wrapper + backups
# ---------------------------------------------------------------------------

@test "mixed: zig release + envs-dev + backup files all swept" {
  fake_zig_release
  fake_zig_dev
  seed_config
  # Backups left by earlier installs.
  printf 'old envs binary\n' > "$TARGET_DIR/envs.bak.20250101-000000"
  ln -s "/nonexistent/old" "$TARGET_DIR/envs-dev.bak.20250101-000000"

  run run_uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET_DIR/envs" ] && [ ! -L "$TARGET_DIR/envs" ]
  [ ! -e "$TARGET_DIR/envs-dev" ] && [ ! -L "$TARGET_DIR/envs-dev" ]
  [ ! -e "$TARGET_DIR/envs.bak.20250101-000000" ]
  [ ! -L "$TARGET_DIR/envs-dev.bak.20250101-000000" ]
  [ ! -d "$ZIG_DIR" ]
  [[ "$output" == *"removed backup: $TARGET_DIR/envs.bak.20250101-000000"* ]]
  [[ "$output" == *"removed backup: $TARGET_DIR/envs-dev.bak.20250101-000000"* ]]
  # Config preserved.
  [ -f "$CONFIG_DIR/config" ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "empty system: clean run on a host with nothing installed" {
  # No fake install — just bare dirs.
  run run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TARGET_DIR/envs not present"* ]]
  [[ "$output" == *"$TARGET_DIR/envs-dev not present"* ]]
}

@test "prod symlink to unrelated target: WARN and left alone" {
  OTHER="$ISOLATED_HOME/usr/local/bin/envs"
  mkdir -p "$(dirname "$OTHER")"
  printf '#!/bin/sh\necho stranger\n' > "$OTHER"
  chmod +x "$OTHER"
  ln -s "$OTHER" "$TARGET_DIR/envs"

  run run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: $TARGET_DIR/envs is a symlink to $OTHER (not our project)"* ]]
  [ -L "$TARGET_DIR/envs" ]
  [ -x "$OTHER" ]
}

@test "prod path is a regular file (not symlink): backed up then swept" {
  printf 'user binary\n' > "$TARGET_DIR/envs"
  chmod +x "$TARGET_DIR/envs"

  run run_uninstall
  [ "$status" -eq 0 ]
  # Step 1: backup created by _remove_prod_link.
  [[ "$output" == *"backed up and removed: $TARGET_DIR/envs"* ]]
  # Step 2: same backup swept by _remove_backups (envs.bak.* glob).
  [[ "$output" == *"removed backup: $TARGET_DIR/envs.bak."* ]]
  [ ! -e "$TARGET_DIR/envs" ]
  # No bak file left behind either.
  ! ls "$TARGET_DIR"/envs.bak.* >/dev/null 2>&1
}

@test "shell rc files: lines reported but never modified" {
  fake_zig_release
  cat > "$ISOLATED_HOME/.zshrc" <<EOF
# pre-existing
export PATH="\$HOME/.local/bin:\$PATH"
source $ENVS_HOME_DIR/envs-source.sh
# end
EOF
  ZSHRC_BEFORE="$(cat "$ISOLATED_HOME/.zshrc")"

  run run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ISOLATED_HOME/.zshrc"* ]]
  [[ "$output" == *"envs-source"* ]]
  [[ "$output" == *".local/bin"* ]]
  # File untouched.
  [ "$(cat "$ISOLATED_HOME/.zshrc")" = "$ZSHRC_BEFORE" ]
}

@test "unknown flag: exit non-zero" {
  run run_uninstall --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown arg"* ]]
}

@test "lib dir kept if it contains unrelated files" {
  fake_zig_release
  printf 'unrelated\n' > "$LIB_DIR/other-file"

  run run_uninstall
  [ "$status" -eq 0 ]
  # $LIB_DIR/envs removed, but $LIB_DIR itself preserved (rmdir failed).
  [ ! -e "$LIB_DIR/envs" ]
  [ -d "$LIB_DIR" ]
  [ -f "$LIB_DIR/other-file" ]
  [[ "$output" == *"$LIB_DIR not empty — left alone"* ]]
}

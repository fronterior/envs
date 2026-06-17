#!/usr/bin/env bats
# tests/install-smoke.bats — end-to-end install smoke for install.sh.
#
# Regression intent (incident on v0.0.2):
#   _atomic_install used "$_dst.new.$$" as the var name $_tmp, clobbering
#   _do_release_install's outer $_tmp (mktemp dir). After the call returned,
#   the post-install `find $_tmp ...` looked at a stale path and produced no
#   root dir, so envs-source.sh / envs-source.fish / envs-dev-source.sh were
#   never copied into $_envs_home. The bats source-mode suite never caught it
#   because it sources the scripts straight from the repo tree, not from the
#   installed location. This smoke runs the real install.sh end-to-end against
#   an isolated HOME and asserts that wrappers actually land on disk.
#
# Isolation:
#   * mktemp -d fake HOME — never reads/writes user dotfiles.
#   * --no-rc / --no-config — install.sh won't prompt or touch real rc files.
#   * release-mode test uses ENVS_RELEASE_TARBALL hook so no network / GitHub.
#   * dev-mode test uses ENVS_SKIP_BUILD=1 hook so no zig build re-run.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT

  SMOKE_HOME="$(mktemp -d -t envs-smoke-home.XXXXXX)"
  export SMOKE_HOME
  export HOME="$SMOKE_HOME"

  # Keep PATH minimal but functional. install.sh wants curl/tar/mktemp/find/awk
  # which all live in standard system dirs.
  export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

  # Force SHELL detection so install.sh's rc-target logic is deterministic.
  # We pass --no-rc anyway, but this avoids surprises if that codepath changes.
  export SHELL="/bin/bash"
}

teardown() {
  if [ -n "${SMOKE_HOME:-}" ] && [ -d "$SMOKE_HOME" ]; then
    case "$SMOKE_HOME" in
      /tmp/*|/var/folders/*|/private/var/folders/*)
        rm -rf "$SMOKE_HOME"
        ;;
      *)
        echo "install-smoke teardown: refusing to rm non-tmp SMOKE_HOME=$SMOKE_HOME" >&2
        ;;
    esac
  fi
  if [ -n "${SMOKE_TARBALL_DIR:-}" ] && [ -d "$SMOKE_TARBALL_DIR" ]; then
    case "$SMOKE_TARBALL_DIR" in
      /tmp/*|/var/folders/*|/private/var/folders/*)
        rm -rf "$SMOKE_TARBALL_DIR"
        ;;
    esac
  fi
}

# Build a fake release tarball that mirrors the .github/workflows/release.yml
# "Stage tarball contents" step. Sets $SMOKE_TARBALL to the path.
_build_release_tarball() {
  SMOKE_TARBALL_DIR="$(mktemp -d -t envs-smoke-tar.XXXXXX)"
  export SMOKE_TARBALL_DIR
  _stage="$SMOKE_TARBALL_DIR/envs-test-triple"
  mkdir -p "$_stage" "$_stage/example"

  # The binary just needs to be present + executable; smoke doesn't run it
  # through release-mode codepath. Reuse the repo's built binary if present,
  # otherwise drop a no-op shell stub (we never invoke it).
  if [ -x "$REPO_ROOT/zig-out/bin/envs" ]; then
    cp "$REPO_ROOT/zig-out/bin/envs" "$_stage/envs"
  else
    printf '#!/bin/sh\nexit 0\n' > "$_stage/envs"
  fi
  chmod 0755 "$_stage/envs"

  cp "$REPO_ROOT/install.sh"          "$_stage/install.sh"
  chmod 0755                          "$_stage/install.sh"
  cp "$REPO_ROOT/envs-source.sh"      "$_stage/envs-source.sh"
  cp "$REPO_ROOT/envs-source.fish"    "$_stage/envs-source.fish"
  cp "$REPO_ROOT/envs-dev-source.sh"  "$_stage/envs-dev-source.sh"
  cp "$REPO_ROOT/README.md"           "$_stage/README.md"
  cp "$REPO_ROOT/example/config"      "$_stage/example/config"

  SMOKE_TARBALL="$SMOKE_TARBALL_DIR/envs-test-triple.tar.xz"
  export SMOKE_TARBALL
  (cd "$SMOKE_TARBALL_DIR" && tar -cJf "envs-test-triple.tar.xz" "envs-test-triple")
}

# ---------- release mode ----------

@test "release mode: installs wrappers + binary into fake HOME" {
  _build_release_tarball

  run env \
    HOME="$SMOKE_HOME" \
    SHELL="/bin/bash" \
    PATH="$PATH" \
    ENVS_RELEASE_TARBALL="$SMOKE_TARBALL" \
    "$REPO_ROOT/install.sh" --release v0.0.smoke --no-rc --no-config
  [ "$status" -eq 0 ] || { echo "install.sh failed:"; echo "$output"; return 1; }

  # Binary + symlink
  [ -x "$SMOKE_HOME/.local/lib/envs/envs" ] \
    || { echo "missing lib binary"; ls -la "$SMOKE_HOME/.local/lib/envs/" 2>&1; return 1; }
  [ -L "$SMOKE_HOME/.local/bin/envs" ] \
    || { echo "missing bin symlink"; ls -la "$SMOKE_HOME/.local/bin/" 2>&1; return 1; }

  # The three wrapper source scripts must be staged at $_envs_home. This is
  # exactly what v0.0.2 missed — the regression case.
  [ -f "$SMOKE_HOME/.local/share/envs/envs-source.sh" ] \
    || { echo "missing envs-source.sh"; ls -la "$SMOKE_HOME/.local/share/envs/" 2>&1; return 1; }
  [ -f "$SMOKE_HOME/.local/share/envs/envs-source.fish" ] \
    || { echo "missing envs-source.fish"; ls -la "$SMOKE_HOME/.local/share/envs/" 2>&1; return 1; }
  [ -f "$SMOKE_HOME/.local/share/envs/envs-dev-source.sh" ] \
    || { echo "missing envs-dev-source.sh"; ls -la "$SMOKE_HOME/.local/share/envs/" 2>&1; return 1; }

  # README + example/config also staged.
  [ -f "$SMOKE_HOME/.local/share/envs/README.md" ]
  [ -f "$SMOKE_HOME/.local/share/envs/example/config" ]
}

@test "release mode: staged envs-source.sh registers shell functions when sourced" {
  _build_release_tarball

  run env \
    HOME="$SMOKE_HOME" \
    SHELL="/bin/bash" \
    PATH="$PATH" \
    ENVS_RELEASE_TARBALL="$SMOKE_TARBALL" \
    "$REPO_ROOT/install.sh" --release v0.0.smoke --no-rc --no-config
  [ "$status" -eq 0 ] || { echo "install.sh failed:"; echo "$output"; return 1; }

  # Sourcing the staged wrapper in a fresh bash should register the public API
  # and `envs-source-status` should run cleanly (returns "inactive").
  run bash -c "
    set -eu
    export HOME='$SMOKE_HOME'
    . '$SMOKE_HOME/.local/share/envs/envs-source.sh'
    declare -f envs-source-activate >/dev/null && echo HAS_ACTIVATE
    declare -f envs-source-deactivate >/dev/null && echo HAS_DEACTIVATE
    envs-source-status
  "
  [ "$status" -eq 0 ] || { echo "source/status failed:"; echo "$output"; return 1; }
  [[ "$output" == *"HAS_ACTIVATE"* ]]
  [[ "$output" == *"HAS_DEACTIVATE"* ]]
  [[ "$output" == *"inactive"* ]]
}

@test "release mode: routing config activates and exports matched keys" {
  _build_release_tarball

  run env \
    HOME="$SMOKE_HOME" \
    SHELL="/bin/bash" \
    PATH="$PATH" \
    ENVS_RELEASE_TARBALL="$SMOKE_TARBALL" \
    "$REPO_ROOT/install.sh" --release v0.0.smoke --no-rc --no-config
  [ "$status" -eq 0 ] || { echo "install.sh failed:"; echo "$output"; return 1; }

  # Build a minimal routing config + matching cwd + .env file, then drive the
  # full flow (cd -> activate -> assert exported key) through the *staged*
  # wrapper.
  _cfg="$SMOKE_HOME/.config/envs"
  mkdir -p "$_cfg"
  cat > "$_cfg/.env.prod" <<'EOF'
KEY_A=prodA
KEY_B=prodB
EOF
  _workdir="$SMOKE_HOME/worktrees/sampleapp-prod"
  mkdir -p "$_workdir"
  cat > "$_cfg/config" <<EOF
<current_dir:*/sampleapp-prod>prod:$_cfg/.env.prod
EOF

  # Bin dir needs the real binary on PATH for `envs --source-match`.
  export PATH="$SMOKE_HOME/.local/bin:$PATH"

  run bash -c "
    set -eu
    export HOME='$SMOKE_HOME'
    export ENVS_CONFIG_DIR='$_cfg'
    export PATH='$SMOKE_HOME/.local/bin:$PATH'
    . '$SMOKE_HOME/.local/share/envs/envs-source.sh'
    cd '$_workdir'
    envs-source-activate prod
    echo KEY_A=\$KEY_A
    echo KEY_B=\$KEY_B
    echo NAME=\$ENVS_SOURCE_NAME
  "
  [ "$status" -eq 0 ] || { echo "routing flow failed:"; echo "$output"; return 1; }
  [[ "$output" == *"KEY_A=prodA"* ]]
  [[ "$output" == *"KEY_B=prodB"* ]]
  [[ "$output" == *"NAME=prod"* ]]
}

# ---------- dev mode ----------

@test "dev mode: installs envs-dev symlink to repo zig-out binary" {
  if [ ! -x "$REPO_ROOT/zig-out/bin/envs" ]; then
    skip "zig-out/bin/envs not built; run 'zig build' first or set up CI build"
  fi

  run env \
    HOME="$SMOKE_HOME" \
    SHELL="/bin/bash" \
    PATH="$PATH" \
    ENVS_SKIP_BUILD=1 \
    "$REPO_ROOT/install.sh" --dev --no-rc --no-config
  [ "$status" -eq 0 ] || { echo "dev install failed:"; echo "$output"; return 1; }

  # Dev mode (no --promote) installs only the envs-dev wrapper symlink.
  [ -L "$SMOKE_HOME/.local/bin/envs-dev" ] \
    || { echo "missing envs-dev symlink"; ls -la "$SMOKE_HOME/.local/bin/" 2>&1; return 1; }
  _target="$(readlink "$SMOKE_HOME/.local/bin/envs-dev")"
  [ "$_target" = "$REPO_ROOT/zig-out/bin/envs" ] \
    || { echo "envs-dev points at '$_target', expected '$REPO_ROOT/zig-out/bin/envs'"; return 1; }

  # Prod slot stays empty — dev mode without --promote must not touch it.
  [ ! -e "$SMOKE_HOME/.local/bin/envs" ] \
    || { echo "dev mode unexpectedly installed prod envs at $SMOKE_HOME/.local/bin/envs"; return 1; }
}

@test "dev mode: --promote installs prod binary + envs symlink" {
  if [ ! -x "$REPO_ROOT/zig-out/bin/envs" ]; then
    skip "zig-out/bin/envs not built; run 'zig build' first or set up CI build"
  fi

  run env \
    HOME="$SMOKE_HOME" \
    SHELL="/bin/bash" \
    PATH="$PATH" \
    ENVS_SKIP_BUILD=1 \
    "$REPO_ROOT/install.sh" --dev --promote --no-rc --no-config
  [ "$status" -eq 0 ] || { echo "dev promote failed:"; echo "$output"; return 1; }

  [ -x "$SMOKE_HOME/.local/lib/envs/envs" ]
  [ -L "$SMOKE_HOME/.local/bin/envs" ]
  [ -L "$SMOKE_HOME/.local/bin/envs-dev" ]
}

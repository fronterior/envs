# tests/helpers/isolate.bash — isolated test fixture for envs source modes.
#
# Exposes (after `isolate_setup`):
#   $ISOLATED_HOME      — fake HOME for the test (no user dotfiles touched)
#   $ENVS_CONFIG_DIR    — fake ~/.config/envs (read by the `envs` binary)
#   $REPO_ROOT          — absolute path to the envs repo (where this test lives)
#   $REPO_DIR_DEV       — directory whose basename matches dev rule
#   $REPO_DIR_PROD      — directory whose basename matches prod rule
#   $REPO_DIR_OTHER     — directory whose basename matches no rule (for cd-away)
#   $BIN_DIR            — dir prepended to PATH containing real `envs` and a mock `envs-dev`
#
# Call `isolate_teardown` from each test's teardown.

isolate_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT

  ISOLATED_HOME="$(mktemp -d -t envs-bats-home.XXXXXX)"
  export ISOLATED_HOME
  export HOME="$ISOLATED_HOME"

  ENVS_CONFIG_DIR="$ISOLATED_HOME/.config/envs"
  export ENVS_CONFIG_DIR
  mkdir -p "$ENVS_CONFIG_DIR"

  # Three dirs whose basenames feed `current_dir` matching.
  REPO_DIR_DEV="$ISOLATED_HOME/worktrees/sampleapp-dev"
  REPO_DIR_DEV2="$ISOLATED_HOME/worktrees/sampleapp-dev2"
  REPO_DIR_PROD="$ISOLATED_HOME/worktrees/sampleapp-prod"
  REPO_DIR_OTHER="$ISOLATED_HOME/worktrees/elsewhere"
  mkdir -p "$REPO_DIR_DEV" "$REPO_DIR_DEV2" "$REPO_DIR_PROD" "$REPO_DIR_OTHER"
  export REPO_DIR_DEV REPO_DIR_DEV2 REPO_DIR_PROD REPO_DIR_OTHER

  # .env files with 3+ keys so the zsh word-splitting case has bite.
  # Two "dev"-named rules with different current_dir match so a single
  # active session sees key swap on cd between matching dirs.
  cat > "$ENVS_CONFIG_DIR/.env.dev" <<'EOF'
KEY_A=devA
KEY_B=devB
KEY_C=devC
EOF
  cat > "$ENVS_CONFIG_DIR/.env.dev2" <<'EOF'
KEY_A=dev2A
KEY_D=dev2D
EOF
  cat > "$ENVS_CONFIG_DIR/.env.prod" <<'EOF'
KEY_A=prodA
KEY_D=prodD
EOF

  # Routing config — use <current_dir:...> so git presence is irrelevant.
  # `current_dir` now globs against the full cwd path; the `*/foo` suffix form
  # pins the match to the last segment so `sampleapp-dev` does not also fire
  # inside `sampleapp-dev2`.
  cat > "$ENVS_CONFIG_DIR/config" <<EOF
<current_dir:*/sampleapp-dev>dev:$ENVS_CONFIG_DIR/.env.dev
<current_dir:*/sampleapp-dev2>dev:$ENVS_CONFIG_DIR/.env.dev2
<current_dir:*/sampleapp-prod>prod:$ENVS_CONFIG_DIR/.env.prod
EOF

  # Stage a private bin dir on PATH with the real envs binary + a mock envs-dev
  # (the dev variant calls `envs-dev`, which doesn't exist outside install.sh).
  BIN_DIR="$ISOLATED_HOME/bin"
  mkdir -p "$BIN_DIR"
  # Prefer the Zig-built binary if present (zig-out/bin/envs); otherwise fall
  # back to the sh implementation in bin/envs. This lets the same bats suite
  # exercise either implementation as long as `zig build` was run beforehand.
  if [ -x "$REPO_ROOT/zig-out/bin/envs" ]; then
    cp "$REPO_ROOT/zig-out/bin/envs" "$BIN_DIR/envs"
  else
    cp "$REPO_ROOT/bin/envs" "$BIN_DIR/envs"
  fi
  chmod +x "$BIN_DIR/envs"
  # envs-dev is just a duplicate of envs for routing purposes; the source script
  # only uses it for `envs-dev --source-match`, which is identical behavior.
  cp "$BIN_DIR/envs" "$BIN_DIR/envs-dev"
  chmod +x "$BIN_DIR/envs-dev"
  export PATH="$BIN_DIR:$PATH"
  export ENVS_DEV_BIN="envs-dev"
}

isolate_teardown() {
  if [ -n "${ISOLATED_HOME:-}" ] && [ -d "$ISOLATED_HOME" ]; then
    case "$ISOLATED_HOME" in
      /tmp/*|/var/folders/*|/private/var/folders/*)
        rm -rf "$ISOLATED_HOME"
        ;;
      *)
        # Refuse to remove anything outside the system tmp tree.
        echo "isolate_teardown: refusing to rm non-tmp ISOLATED_HOME=$ISOLATED_HOME" >&2
        ;;
    esac
  fi
}

# Print the snippet that a sh-based test will source inside its spawned shell.
# It pulls PATH/HOME/ENVS_CONFIG_DIR/REPO_ROOT from the bats env (already exported)
# and sources the requested source script.
#
# Usage: print_sh_setup envs-source.sh   (or envs-dev-source.sh)
print_sh_setup() {
  _script="$1"
  cat <<EOF
export PATH="$BIN_DIR:\$PATH"
export HOME="$ISOLATED_HOME"
export ENVS_CONFIG_DIR="$ENVS_CONFIG_DIR"
export ENVS_DEV_BIN="envs-dev"
. "$REPO_ROOT/$_script"
EOF
}

# Fish equivalent.
print_fish_setup() {
  cat <<EOF
set -gx PATH "$BIN_DIR" \$PATH
set -gx HOME "$ISOLATED_HOME"
set -gx ENVS_CONFIG_DIR "$ENVS_CONFIG_DIR"
source "$REPO_ROOT/envs-source.fish"
EOF
}

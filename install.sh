#!/bin/sh
# install.sh — envs installer
# Modes:
#   1) local  — when run from inside a checkout, symlinks bin/envs into ~/.local/bin
#   2) remote — when piped from curl, git-clones into $ENVS_HOME then symlinks
#
# Env overrides:
#   ENVS_REPO_URL  default: https://github.com/fronterior/envs
#   ENVS_HOME      default: ~/.local/share/envs (for remote mode)

set -eu

_repo_url="${ENVS_REPO_URL:-https://github.com/fronterior/envs}"
_envs_home="${ENVS_HOME:-$HOME/.local/share/envs}"
_target_dir="$HOME/.local/bin"

# Self-detect mode
_self="$0"
_self_dir=""
if [ -f "$_self" ]; then
  _self_dir="$(cd "$(dirname "$_self")" && pwd)"
fi

if [ -n "$_self_dir" ] && [ -f "$_self_dir/bin/envs" ]; then
  _proj_dir="$_self_dir"
  echo "envs: local install from $_proj_dir"
else
  # Remote mode — clone or update
  echo "envs: remote install from $_repo_url"
  if [ ! -d "$_envs_home/.git" ]; then
    mkdir -p "$(dirname "$_envs_home")"
    git clone --depth 1 "$_repo_url" "$_envs_home"
  else
    echo "envs: $_envs_home exists, pulling latest"
    (cd "$_envs_home" && git pull --ff-only)
  fi
  _proj_dir="$_envs_home"
fi

mkdir -p "$_target_dir"

_install_link() {
  _name="$1"
  _src="$_proj_dir/bin/$_name"
  _dst="$_target_dir/$_name"
  if [ ! -f "$_src" ]; then
    echo "envs: skip (missing source): $_src"
    return 0
  fi
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_src" ]; then
    echo "OK: $_dst already linked"
    return 0
  fi
  if [ -e "$_dst" ] || [ -L "$_dst" ]; then
    mv "$_dst" "$_dst.bak.$(date +%Y%m%d-%H%M%S)"
    echo "backed up old $_dst"
  fi
  ln -s "$_src" "$_dst"
  echo "linked: $_dst -> $_src"
}

_install_link envs

# Seed ~/.config/envs/config from example if not present (existing config is preserved).
_config_dir="$HOME/.config/envs"
_config_file="$_config_dir/config"
_example_config="$_proj_dir/example/config"
if [ -e "$_config_file" ]; then
  echo "config already present at $_config_file - keeping it"
elif [ -f "$_example_config" ]; then
  mkdir -p "$_config_dir"
  cp "$_example_config" "$_config_file"
  echo "seeded config from example: $_config_file"
else
  echo "WARN: example/config not found at $_example_config - skipping config seed"
fi

case ":$PATH:" in
  *":$_target_dir:"*)
    echo "PATH OK: $_target_dir is in PATH"
    ;;
  *)
    # PATH not set — detect shell, prompt to add
    _shell=$(basename "${SHELL:-}")
    _rc=""
    case "$_shell" in
      zsh) _rc="$HOME/.zshrc" ;;
      bash)
        if [ -f "$HOME/.bashrc" ]; then
          _rc="$HOME/.bashrc"
        elif [ -f "$HOME/.bash_profile" ]; then
          _rc="$HOME/.bash_profile"
        fi
        ;;
      sh|dash|ash) _rc="$HOME/.profile" ;;
    esac

    _path_line='export PATH="$HOME/.local/bin:$PATH"'

    if [ -z "$_rc" ] || [ ! -e /dev/tty ]; then
      # Can't detect shell or no tty — print manual instruction
      echo "WARN: $_target_dir is not in PATH"
      echo "  Add this to your shell rc: $_path_line"
    elif grep -qF "$_target_dir" "$_rc" 2>/dev/null; then
      # Line already in rc — just remind to source
      echo "PATH line for $_target_dir already in $_rc"
      echo "  Run: source $_rc  (or open a new shell)"
    else
      # Prompt user via /dev/tty
      printf "envs: %s is not in PATH. Add to %s? [y/N] " "$_target_dir" "$_rc"
      _yn=""
      read -r _yn < /dev/tty || _yn=""
      case "$_yn" in
        y|Y|yes|YES)
          printf '\n# Added by envs install.sh\n%s\n' "$_path_line" >> "$_rc"
          echo "added PATH line to $_rc"
          echo "  Run: source $_rc  (or open a new shell)"
          ;;
        *)
          echo "skipped — add this manually to $_rc:"
          echo "  $_path_line"
          ;;
      esac
    fi
    ;;
esac

echo
echo "Next: 1) add routing rules to ~/.config/envs/config  2) use 'envs <env_name> <cmd>'"

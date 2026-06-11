#!/bin/sh
# uninstall.sh — envs uninstaller
# Removes ~/.local/bin/envs symlink/file. Preserves your ~/.config/envs/* (secrets).
# Works both locally (./uninstall.sh) and via curl one-liner.
#
# Env overrides:
#   ENVS_HOME  default: ~/.local/share/envs (the clone dir, if remote install used)

set -eu

_envs_home="${ENVS_HOME:-$HOME/.local/share/envs}"
_target="$HOME/.local/bin/envs"

# Self-detect project location (for symlink-target comparison)
_self="$0"
_self_dir=""
if [ -f "$_self" ]; then
  _self_dir="$(cd "$(dirname "$_self")" && pwd)"
fi

_remove_link() {
  _dst="$1"
  if [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; then
    echo "OK: $_dst not present (nothing to remove)"
    return 0
  fi
  if [ -L "$_dst" ]; then
    _link=$(readlink "$_dst")
    # Match if symlink points at our project bin (local checkout or $_envs_home clone)
    case "$_link" in
      "$_self_dir/bin/envs"|"$_envs_home/bin/envs")
        rm "$_dst"
        echo "removed symlink: $_dst -> $_link"
        ;;
      *)
        echo "WARN: $_dst is a symlink to $_link (not our project) — leaving alone"
        ;;
    esac
  else
    # Regular file — back up then remove
    mv "$_dst" "$_dst.bak.$(date +%Y%m%d-%H%M%S)"
    echo "backed up and removed: $_dst (now at $_dst.bak.<ts>)"
  fi
}

_remove_link "$_target"

# Clone dir notice (don't auto-delete — might contain user's local edits)
if [ -d "$_envs_home/.git" ]; then
  echo
  echo "NOTE: clone at $_envs_home is preserved. To remove: rm -rf \"$_envs_home\""
fi

# Config preservation notice
if [ -d "$HOME/.config/envs" ]; then
  echo
  echo "NOTE: your routing config and env files at \$HOME/.config/envs/ are preserved."
  echo "      To remove them too: rm -rf \"\$HOME/.config/envs\""
fi

echo
echo "Done. PATH was not modified."

#!/bin/sh
# uninstall.sh — envs uninstaller (zig-era aware)
#
# Removes installed binaries, symlinks, staged release files, and the managed
# zig cache. Preserves your ~/.config/envs/* (secrets) by default and never
# edits your shell rc files (only reports lines it found).
#
# Layout this script knows about (must match install.sh):
#   $_target_dir/envs           — prod symlink -> $_lib_dir/envs OR <repo>/bin/envs
#                                 (old sh era) OR <repo>/zig-out/bin/envs
#   $_target_dir/envs-dev       — dev wrapper -> <repo>/zig-out/bin/envs
#   $_target_dir/envs.bak.*     — backup files from prior installs
#   $_target_dir/envs-dev.bak.* — backup files from prior installs
#   $_lib_dir/envs              — installed zig binary (release mode)
#   $_man_dir/envs.1            — installed man page (release/dev mode)
#   $_envs_home                 — release stage dir (source files + example/)
#   $_zig_dir                   — managed zig cache (~/.local/share/envs/zig)
#   $HOME/.config/envs/         — user secrets (preserved unless --purge-config)
#
# Env overrides (match install.sh):
#   ENVS_HOME         default: ~/.local/share/envs
#   ENVS_LIB_DIR      default: ~/.local/lib/envs
#   ENVS_TARGET_DIR   default: ~/.local/bin
#   ENVS_MAN_DIR      default: ~/.local/share/man/man1
#   ENVS_ZIG_DIR      default: ~/.local/share/envs/zig
#
# Flags:
#   --keep-zig        keep the managed zig cache at $ENVS_ZIG_DIR
#   --purge-config    also remove ~/.config/envs (default: preserved)
#   -h | --help       help

set -eu

# ---------- defaults ----------
_envs_home="${ENVS_HOME:-$HOME/.local/share/envs}"
_lib_dir="${ENVS_LIB_DIR:-$HOME/.local/lib/envs}"
_target_dir="${ENVS_TARGET_DIR:-$HOME/.local/bin}"
_man_dir="${ENVS_MAN_DIR:-$HOME/.local/share/man/man1}"
_zig_dir="${ENVS_ZIG_DIR:-$HOME/.local/share/envs/zig}"

_keep_zig=0
_purge_config=0

# ---------- arg parse ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-zig)     _keep_zig=1 ;;
    --purge-config) _purge_config=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "envs uninstall: unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# ---------- self-detect project location ----------
_self="$0"
_self_dir=""
if [ -f "$_self" ]; then
  _self_dir="$(cd "$(dirname "$_self")" && pwd)"
fi

# ---------- helpers ----------

# Remove prod-link $_target_dir/envs if it points at a known envs install.
# Match rules (link target):
#   <self>/bin/envs                        (sh-era checkout)
#   <self>/zig-out/bin/envs                (zig-era checkout)
#   $_envs_home/bin/envs                   (sh-era clone)
#   $_envs_home/zig-out/bin/envs           (zig-era clone)
#   $_lib_dir/envs                         (zig-era release install)
#   $HOME/.local/lib/envs/envs             (default $_lib_dir, explicit)
_remove_prod_link() {
  _dst="$1"
  if [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; then
    echo "OK: $_dst not present (nothing to remove)"
    return 0
  fi
  if [ -L "$_dst" ]; then
    _link=$(readlink "$_dst")
    case "$_link" in
      "$_self_dir/bin/envs"|\
      "$_self_dir/zig-out/bin/envs"|\
      "$_envs_home/bin/envs"|\
      "$_envs_home/zig-out/bin/envs"|\
      "$_lib_dir/envs"|\
      "$HOME/.local/lib/envs/envs")
        rm "$_dst"
        echo "removed symlink: $_dst -> $_link"
        ;;
      *)
        echo "WARN: $_dst is a symlink to $_link (not our project) — leaving alone"
        ;;
    esac
  else
    # Regular file — back up then remove (don't lose user-installed binaries).
    mv "$_dst" "$_dst.bak.$(date +%Y%m%d-%H%M%S)"
    echo "backed up and removed: $_dst (now at $_dst.bak.<ts>)"
  fi
}

# Remove dev-wrapper $_target_dir/envs-dev. Only matches when the symlink
# target ends with /zig-out/bin/envs (our dev wrapper signature). Other
# targets are left alone with a WARN — we don't risk clobbering a user's
# unrelated dev binary.
_remove_dev_link() {
  _dst="$1"
  if [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; then
    echo "OK: $_dst not present (nothing to remove)"
    return 0
  fi
  if [ -L "$_dst" ]; then
    _link=$(readlink "$_dst")
    case "$_link" in
      */zig-out/bin/envs)
        rm "$_dst"
        echo "removed symlink: $_dst -> $_link"
        ;;
      *)
        echo "WARN: $_dst is a symlink to $_link (not our dev wrapper) — leaving alone"
        ;;
    esac
  else
    mv "$_dst" "$_dst.bak.$(date +%Y%m%d-%H%M%S)"
    echo "backed up and removed: $_dst (now at $_dst.bak.<ts>)"
  fi
}

# Sweep backup files created by prior installs (install.sh `_link_force` rename).
# Removes both real files and stale symlinks named *.bak.*.
_remove_backups() {
  for _bak in \
    "$_target_dir/envs.bak."* \
    "$_target_dir/envs-dev.bak."*
  do
    if [ -e "$_bak" ] || [ -L "$_bak" ]; then
      rm -f "$_bak"
      echo "removed backup: $_bak"
    fi
  done
}

# Remove staged release files inside $_envs_home (install.sh _do_release_install
# stages these). Only touches the file names we know we wrote; never blindly
# rm -rf the whole dir (user may have unrelated content). If the dir is a
# self-clone (.git/ present), nuke it whole — that's a remote-install artifact.
_clean_envs_home() {
  if [ ! -d "$_envs_home" ]; then
    return 0
  fi

  if [ -d "$_envs_home/.git" ]; then
    # Remote install one-liner cloned the repo here — safe to nuke wholesale.
    rm -rf "$_envs_home"
    echo "removed clone: $_envs_home"
    return 0
  fi

  # Stage-only mode: remove known artefacts only.
  for _f in \
    "$_envs_home/envs-source.sh" \
    "$_envs_home/envs-dev-source.sh" \
    "$_envs_home/envs-source.fish" \
    "$_envs_home/README.md"
  do
    if [ -f "$_f" ] || [ -L "$_f" ]; then
      rm -f "$_f"
      echo "removed: $_f"
    fi
  done
  if [ -d "$_envs_home/example" ]; then
    rm -rf "$_envs_home/example"
    echo "removed: $_envs_home/example"
  fi
  # Old sh-era $_envs_home may have had bin/envs.
  if [ -e "$_envs_home/bin/envs" ] || [ -L "$_envs_home/bin/envs" ]; then
    rm -f "$_envs_home/bin/envs"
    echo "removed: $_envs_home/bin/envs"
  fi
  if [ -d "$_envs_home/bin" ]; then
    # Only remove bin/ if it's empty after the above sweep.
    rmdir "$_envs_home/bin" 2>/dev/null && echo "removed: $_envs_home/bin" || true
  fi

  # Special case: $_zig_dir defaults to $_envs_home/zig. If $_envs_home is
  # otherwise empty AFTER zig removal (handled below), we'll rmdir it then.
  # Don't rmdir here — zig sweep happens after.
}

# Report shell-rc lines that reference envs without modifying them.
_report_rc_lines() {
  _hit=0
  for _rc in \
    "$HOME/.zshrc" \
    "$HOME/.bashrc" \
    "$HOME/.bash_profile" \
    "$HOME/.profile" \
    "$HOME/.config/fish/config.fish"
  do
    [ -f "$_rc" ] || continue
    # Match envs-source* lines OR PATH lines that mention .local/bin
    # (the install.sh source-line and PATH-prompt outputs).
    _matches="$(grep -nE 'envs-source|envs-dev-source|\.local/bin' "$_rc" 2>/dev/null || true)"
    if [ -n "$_matches" ]; then
      if [ "$_hit" = "0" ]; then
        echo
        echo "NOTE: shell rc files reference envs / ~/.local/bin. These are preserved."
        echo "      Edit them manually to fully remove envs from your shell:"
        _hit=1
      fi
      printf '%s\n' "$_matches" | while IFS= read -r _line; do
        echo "  $_rc:$_line"
      done
    fi
  done
}

# ---------- do the work ----------

# 1. prod symlink / file
_remove_prod_link "$_target_dir/envs"

# 2. dev wrapper
_remove_dev_link "$_target_dir/envs-dev"

# 3. backup files left by previous installs
_remove_backups

# 4. installed zig binary at $_lib_dir/envs (release mode)
if [ -e "$_lib_dir/envs" ] || [ -L "$_lib_dir/envs" ]; then
  rm -f "$_lib_dir/envs"
  echo "removed: $_lib_dir/envs"
fi
# Drop $_lib_dir if empty (safe — install.sh creates it for this single file).
if [ -d "$_lib_dir" ]; then
  rmdir "$_lib_dir" 2>/dev/null && echo "removed: $_lib_dir" || \
    echo "NOTE: $_lib_dir not empty — left alone"
fi

# 4b. installed man page at $_man_dir/envs.1
if [ -e "$_man_dir/envs.1" ] || [ -L "$_man_dir/envs.1" ]; then
  rm -f "$_man_dir/envs.1"
  echo "removed: $_man_dir/envs.1"
fi

# 5. release-stage files at $_envs_home
_clean_envs_home

# 6. managed zig cache
if [ "$_keep_zig" = "1" ]; then
  if [ -d "$_zig_dir" ]; then
    echo "NOTE: managed zig cache preserved (--keep-zig): $_zig_dir"
  fi
else
  if [ -d "$_zig_dir" ]; then
    rm -rf "$_zig_dir"
    echo "removed: $_zig_dir (managed zig cache)"
  fi
fi

# 7. final tidy: rmdir $_envs_home if it's now empty (no .git, no stage files,
#    no zig cache). This catches the case where $_envs_home was only used to
#    hold $_zig_dir at its default path.
if [ -d "$_envs_home" ]; then
  rmdir "$_envs_home" 2>/dev/null && echo "removed: $_envs_home" || true
fi

# 8. ~/.config/envs — user secrets
if [ -d "$HOME/.config/envs" ]; then
  if [ "$_purge_config" = "1" ]; then
    rm -rf "$HOME/.config/envs"
    echo "removed: $HOME/.config/envs (--purge-config)"
  else
    echo
    echo "NOTE: your routing config and env files at \$HOME/.config/envs/ are preserved."
    echo "      To remove them too: rm -rf \"\$HOME/.config/envs\"  (or rerun with --purge-config)"
  fi
fi

# 9. report shell-rc lines (read-only — never edits)
_report_rc_lines

echo
echo "Done. PATH was not modified."

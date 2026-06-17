#!/bin/sh
# install.sh — envs installer (dev / end-user dual mode)
#
# Modes (auto-detected, override-able):
#   dev       — script is inside a checkout with build.zig + .git/, no --release.
#               Ensures zig >= 0.16, runs `zig build`, installs a dev wrapper
#               symlink at $TARGET_DIR/envs-dev pointing at <repo>/zig-out/bin/envs.
#               Existing prod $TARGET_DIR/envs is untouched until --promote.
#   release   — curl-piped single file, or --release [tag] given.
#               Downloads the matching tarball from GitHub Releases and installs
#               the binary at $LIB_DIR/envs with symlink $TARGET_DIR/envs.
#   --promote — only meaningful in a checkout. Builds Zig binary with ReleaseFast
#               and atomically replaces $LIB_DIR/envs + $TARGET_DIR/envs symlink.
#
# Flags:
#   --release [tag]   force end-user mode (optional explicit tag like v0.1.0)
#   --promote         dev -> prod promote (build local zig binary into prod slot)
#   --dev             force dev mode (require build.zig in script dir)
#   --no-config       skip example/config seed
#   --no-rc           skip rc-file source line / PATH prompt
#   -h | --help       help
#
# Env overrides:
#   ENVS_REPO          default: fronterior/envs    (owner/name for Release API)
#   ENVS_HOME          default: $HOME/.local/share/envs
#   ENVS_LIB_DIR       default: $HOME/.local/lib/envs
#   ENVS_TARGET_DIR    default: $HOME/.local/bin
#   ENVS_ZIG_DIR       default: $HOME/.local/share/envs/zig (managed zig cache)
#   ENVS_ZIG_VERSION   default: 0.16.0             (min + managed install version)

set -eu

# ---------- defaults ----------
_repo="${ENVS_REPO:-fronterior/envs}"
_envs_home="${ENVS_HOME:-$HOME/.local/share/envs}"
_lib_dir="${ENVS_LIB_DIR:-$HOME/.local/lib/envs}"
_target_dir="${ENVS_TARGET_DIR:-$HOME/.local/bin}"
_zig_dir="${ENVS_ZIG_DIR:-$HOME/.local/share/envs/zig}"
_zig_min_version="${ENVS_ZIG_VERSION:-0.16.0}"

_mode=""          # "dev" | "release" — resolved below
_release_tag=""   # explicit tag if --release vX.Y.Z given (else "latest")
_promote=0
_seed_config=1
_touch_rc=1

# ---------- arg parse ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --release)
      _mode="release"
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
        _release_tag="$2"
        shift
      fi
      ;;
    --release=*) _mode="release"; _release_tag="${1#--release=}" ;;
    --promote)   _promote=1 ;;
    --dev)       _mode="dev" ;;
    --no-config) _seed_config=0 ;;
    --no-rc)     _touch_rc=0 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "envs: unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# ---------- detect script dir + repo root ----------
_self="$0"
_self_dir=""
if [ -f "$_self" ]; then
  _self_dir="$(cd "$(dirname "$_self")" && pwd)"
fi

# ---------- mode detection ----------
if [ -z "$_mode" ]; then
  if [ -n "$_self_dir" ] && [ -f "$_self_dir/build.zig" ] && [ -d "$_self_dir/.git" ]; then
    _mode="dev"
  else
    _mode="release"
  fi
fi

if [ "$_promote" = "1" ] && [ "$_mode" != "dev" ]; then
  echo "envs: --promote requires dev mode (run from a checkout)" >&2
  exit 2
fi

if [ "$_promote" = "1" ]; then
  echo "envs: install mode = $_mode (+promote)"
else
  echo "envs: install mode = $_mode"
fi

mkdir -p "$_target_dir" "$_lib_dir"

# ---------- platform detect ----------
_uname_s="$(uname -s)"
_uname_m="$(uname -m)"

case "$_uname_s" in
  Darwin) _os="macos" ;;
  Linux)  _os="linux" ;;
  *) echo "envs: unsupported OS: $_uname_s" >&2; exit 1 ;;
esac
case "$_uname_m" in
  arm64|aarch64) _arch="aarch64" ;;
  x86_64|amd64)  _arch="x86_64" ;;
  *) echo "envs: unsupported arch: $_uname_m" >&2; exit 1 ;;
esac

_target_triple="${_arch}-${_os}"
_asset_name="envs-${_target_triple}.tar.xz"

# ---------- helpers ----------
_have() { command -v "$1" >/dev/null 2>&1; }

# semver-ish compare: returns 0 if $1 >= $2, else 1. (major.minor.patch)
_ver_ge() {
  _a="$1"; _b="$2"
  # strip leading v
  _a="${_a#v}"; _b="${_b#v}"
  # zero-pad each segment
  # shellcheck disable=SC2046  # word splitting intentional: 6 fields for set
  set -- $(printf '%s\n%s\n' "$_a" "$_b" | awk -F. '{ printf "%d %d %d\n", $1+0, $2+0, $3+0 }')
  _a_maj=$1; _a_min=$2; _a_pat=$3
  _b_maj=$4; _b_min=$5; _b_pat=$6
  [ "$_a_maj" -gt "$_b_maj" ] && return 0
  [ "$_a_maj" -lt "$_b_maj" ] && return 1
  [ "$_a_min" -gt "$_b_min" ] && return 0
  [ "$_a_min" -lt "$_b_min" ] && return 1
  [ "$_a_pat" -ge "$_b_pat" ] && return 0
  return 1
}

# Set $_zig_bin to a usable zig (system zig if >= min, else managed install).
_resolve_zig() {
  _zig_bin=""
  if _have zig; then
    _sys_ver="$(zig version 2>/dev/null | head -n1 || true)"
    if [ -n "$_sys_ver" ] && _ver_ge "$_sys_ver" "$_zig_min_version"; then
      _zig_bin="$(command -v zig)"
      echo "envs: using system zig $_sys_ver ($_zig_bin)"
      return 0
    else
      echo "envs: system zig=$_sys_ver below $_zig_min_version — installing managed copy"
    fi
  else
    echo "envs: no system zig — installing managed copy ($_zig_min_version)"
  fi

  _zig_install_dir="$_zig_dir/$_zig_min_version"
  _zig_bin="$_zig_install_dir/zig"
  if [ -x "$_zig_bin" ]; then
    echo "envs: managed zig already present at $_zig_bin"
    return 0
  fi

  # Tarball naming on ziglang.org: zig-<arch>-<os>-<version>.tar.xz
  # Arch token: x86_64, aarch64. OS token: macos, linux.
  _zig_tar="zig-${_arch}-${_os}-${_zig_min_version}.tar.xz"
  _zig_url="https://ziglang.org/download/${_zig_min_version}/${_zig_tar}"

  mkdir -p "$_zig_install_dir"
  _tmp="$(mktemp -d -t envs-zig.XXXXXX)"
  echo "envs: downloading $_zig_url"
  if _have curl; then
    curl -fL --retry 3 -o "$_tmp/$_zig_tar" "$_zig_url"
  elif _have wget; then
    wget -O "$_tmp/$_zig_tar" "$_zig_url"
  else
    echo "envs: need curl or wget to download zig" >&2
    exit 1
  fi

  echo "envs: extracting zig"
  tar -xJf "$_tmp/$_zig_tar" -C "$_tmp"
  _extracted="$(find "$_tmp" -maxdepth 1 -mindepth 1 -type d -name 'zig-*' | head -n1)"
  if [ -z "$_extracted" ] || [ ! -x "$_extracted/zig" ]; then
    echo "envs: zig extraction failed" >&2
    rm -rf "$_tmp"
    exit 1
  fi

  # Move into managed dir (replace any partial install).
  rm -rf "$_zig_install_dir"
  mv "$_extracted" "$_zig_install_dir"
  rm -rf "$_tmp"
  if [ ! -x "$_zig_bin" ]; then
    echo "envs: managed zig binary not found at $_zig_bin" >&2
    exit 1
  fi
  echo "envs: managed zig installed at $_zig_bin"
}

# atomic mv replacement at $1 -> $2. $1 must exist.
_atomic_install() {
  _src="$1"; _dst="$2"
  _dst_dir="$(dirname "$_dst")"
  mkdir -p "$_dst_dir"
  _tmp="$_dst.new.$$"
  cp "$_src" "$_tmp"
  chmod 0755 "$_tmp"
  mv -f "$_tmp" "$_dst"
}

_link_force() {
  _src="$1"; _dst="$2"
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

# ---------- dev mode ----------
_do_dev_build() {
  if [ ! -f "$_self_dir/build.zig" ]; then
    echo "envs: dev mode requires build.zig in $_self_dir" >&2
    exit 1
  fi
  _resolve_zig
  echo "envs: building (zig build --release=fast) in $_self_dir"
  (cd "$_self_dir" && "$_zig_bin" build --release=fast)
  if [ ! -x "$_self_dir/zig-out/bin/envs" ]; then
    echo "envs: build did not produce zig-out/bin/envs" >&2
    exit 1
  fi
}

_install_dev_link() {
  _link_force "$_self_dir/zig-out/bin/envs" "$_target_dir/envs-dev"
}

_install_promote() {
  echo "envs: promoting zig-out/bin/envs to prod ($_lib_dir/envs)"
  _atomic_install "$_self_dir/zig-out/bin/envs" "$_lib_dir/envs"
  _link_force "$_lib_dir/envs" "$_target_dir/envs"
  # Refresh dev wrapper too (binary at zig-out is the same content).
  _link_force "$_self_dir/zig-out/bin/envs" "$_target_dir/envs-dev"
}

# ---------- release mode ----------
_release_resolve_url() {
  # Sets $_release_dl_url + $_release_tag_resolved
  _api_base="https://api.github.com/repos/$_repo"
  if [ -n "$_release_tag" ]; then
    _api_url="$_api_base/releases/tags/$_release_tag"
  else
    _api_url="$_api_base/releases/latest"
  fi

  if ! _have curl; then
    echo "envs: curl is required for release mode" >&2
    exit 1
  fi

  echo "envs: querying $_api_url"
  _json="$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "$_api_url")" || {
      echo "envs: failed to query GitHub Release API" >&2
      exit 1
    }

  _release_tag_resolved="$(printf '%s\n' "$_json" \
    | awk -F'"' '/"tag_name"[[:space:]]*:/ { print $4; exit }')"
  _release_dl_url="$(printf '%s\n' "$_json" \
    | awk -F'"' -v want="$_asset_name" '
        /"browser_download_url"[[:space:]]*:/ {
          if ($4 ~ want) { print $4; exit }
        }')"

  if [ -z "$_release_dl_url" ]; then
    echo "envs: asset $_asset_name not found in release ${_release_tag_resolved:-latest}" >&2
    exit 1
  fi
  echo "envs: release tag = $_release_tag_resolved"
  echo "envs: asset       = $_release_dl_url"
}

_do_release_install() {
  _release_resolve_url
  _tmp="$(mktemp -d -t envs-install.XXXXXX)"
  echo "envs: downloading $_asset_name"
  curl -fL --retry 3 -o "$_tmp/$_asset_name" "$_release_dl_url"
  echo "envs: extracting"
  tar -xJf "$_tmp/$_asset_name" -C "$_tmp"

  _bin_src="$(find "$_tmp" -maxdepth 3 -type f -name envs -perm -u+x | head -n1)"
  if [ -z "$_bin_src" ] || [ ! -x "$_bin_src" ]; then
    echo "envs: extracted tarball missing executable 'envs'" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  _atomic_install "$_bin_src" "$_lib_dir/envs"
  _link_force "$_lib_dir/envs" "$_target_dir/envs"

  # The tarball also carries source files + example. Stage them under $_envs_home
  # so that rc-file source lines have a stable absolute path.
  mkdir -p "$_envs_home"
  _root_dir="$(find "$_tmp" -maxdepth 2 -mindepth 1 -type d | head -n1)"
  if [ -z "$_root_dir" ]; then _root_dir="$_tmp"; fi
  for _f in envs-source.sh envs-dev-source.sh envs-source.fish; do
    if [ -f "$_root_dir/$_f" ]; then
      cp "$_root_dir/$_f" "$_envs_home/$_f"
    fi
  done
  if [ -d "$_root_dir/example" ]; then
    mkdir -p "$_envs_home/example"
    cp -R "$_root_dir/example/." "$_envs_home/example/"
  fi
  if [ -f "$_root_dir/README.md" ]; then
    cp "$_root_dir/README.md" "$_envs_home/README.md"
  fi

  # Future config seed + rc lines reference this stable dir.
  _proj_dir="$_envs_home"
  rm -rf "$_tmp"
}

# ---------- dispatch ----------
if [ "$_mode" = "dev" ]; then
  _do_dev_build
  if [ "$_promote" = "1" ]; then
    _install_promote
  else
    _install_dev_link
  fi
  _proj_dir="$_self_dir"
else
  _do_release_install
fi

# ---------- config seed ----------
if [ "$_seed_config" = "1" ]; then
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
fi

# ---------- shell rc lines ----------
if [ "$_touch_rc" = "1" ]; then
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
    fish) _rc="$HOME/.config/fish/config.fish" ;;
    sh|dash|ash) _rc="$HOME/.profile" ;;
  esac

  # PATH
  case ":$PATH:" in
    *":$_target_dir:"*)
      echo "PATH OK: $_target_dir is in PATH"
      ;;
    *)
      # shellcheck disable=SC2016  # $HOME/$PATH must expand at user shell startup, not now
      _path_line='export PATH="$HOME/.local/bin:$PATH"'
      if [ "$_shell" = "fish" ]; then
        # shellcheck disable=SC2016
        _path_line='set -gx PATH $HOME/.local/bin $PATH'
      fi
      if [ -z "$_rc" ] || [ ! -e /dev/tty ]; then
        echo "WARN: $_target_dir is not in PATH"
        echo "  Add this to your shell rc: $_path_line"
      elif grep -qF '.local/bin' "$_rc" 2>/dev/null; then
        echo "PATH line for $_target_dir already in $_rc"
        echo "  Run: source $_rc  (or open a new shell)"
      else
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
            echo "skipped - add this manually to $_rc:"
            echo "  $_path_line"
            ;;
        esac
      fi
      ;;
  esac

  # envs-source line
  case "$_shell" in
    fish) _source_file="$_proj_dir/envs-source.fish" ;;
    *)    _source_file="$_proj_dir/envs-source.sh" ;;
  esac

  if [ -n "$_rc" ] && [ -f "$_source_file" ]; then
    if grep -qF "envs-source" "$_rc" 2>/dev/null; then
      echo "envs-source: source line already in $_rc"
    elif [ ! -e /dev/tty ]; then
      echo "INFO: envs-source not auto-enabled. To enable later:"
      echo "  echo 'source $_source_file' >> $_rc"
    else
      printf "envs: enable envs-source-* shell functions in %s? [y/N] " "$_rc"
      _yn2=""
      read -r _yn2 < /dev/tty || _yn2=""
      case "$_yn2" in
        y|Y|yes|YES)
          printf '\n# Added by envs install.sh\nsource %s\n' "$_source_file" >> "$_rc"
          echo "added source line to $_rc"
          echo "  Run: source $_rc  (or open a new shell), then: envs-source-activate"
          ;;
        *)
          echo "skipped - to enable later: echo 'source $_source_file' >> $_rc"
          ;;
      esac
    fi
  fi

  # In dev mode, also offer the envs-dev-source.sh line (separate from prod).
  if [ "$_mode" = "dev" ] && [ "$_shell" != "fish" ]; then
    _dev_source_file="$_proj_dir/envs-dev-source.sh"
    if [ -n "$_rc" ] && [ -f "$_dev_source_file" ]; then
      if grep -qF "envs-dev-source" "$_rc" 2>/dev/null; then
        echo "envs-dev-source: source line already in $_rc"
      elif [ ! -e /dev/tty ]; then
        echo "INFO: envs-dev-source not auto-enabled. To enable later:"
        echo "  echo 'source $_dev_source_file' >> $_rc"
      else
        printf "envs: enable envs-dev-source-* shell functions in %s? [y/N] " "$_rc"
        _yn3=""
        read -r _yn3 < /dev/tty || _yn3=""
        case "$_yn3" in
          y|Y|yes|YES)
            printf '\n# Added by envs install.sh\nsource %s\n' "$_dev_source_file" >> "$_rc"
            echo "added dev source line to $_rc"
            ;;
          *)
            echo "skipped - to enable later: echo 'source $_dev_source_file' >> $_rc"
            ;;
        esac
      fi
    fi
  fi
fi

echo
case "$_mode" in
  dev)
    if [ "$_promote" = "1" ]; then
      echo "envs: prod binary installed at $_lib_dir/envs (-> $_target_dir/envs)"
      echo "      dev wrapper at $_target_dir/envs-dev -> $_self_dir/zig-out/bin/envs"
    else
      echo "envs: dev wrapper installed at $_target_dir/envs-dev -> $_self_dir/zig-out/bin/envs"
      echo "      prod $_target_dir/envs untouched (run with --promote to update prod)."
    fi
    ;;
  release)
    echo "envs: installed $_release_tag_resolved at $_lib_dir/envs (-> $_target_dir/envs)"
    ;;
esac
echo "Next: 1) add routing rules to ~/.config/envs/config  2) use 'envs <env_name> <cmd>'"
echo "      or 'envs-source-activate [name]' for virtualenv-style mode"

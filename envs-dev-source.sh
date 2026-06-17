# envs-dev-source.sh — dev variant of envs-source. Calls envs-dev binary, uses ENVS_DEV_SOURCE_* env vars.

envs-dev-source-activate() {
  _new_name="${1:-}"
  _envs_dev_bin="${ENVS_DEV_BIN:-envs-dev}"

  if [ -n "${ENVS_DEV_SOURCE_ACTIVE:-}" ]; then
    _envs_dev_source_restore_keys
    ENVS_DEV_SOURCE_NAME="$_new_name"
    ENVS_DEV_SOURCE_INJECTED_KEYS=""
    ENVS_DEV_SOURCE_LAST_MATCHED=""
    # Reset PWD cache so next precmd re-evaluates under the new name.
    ENVS_DEV_SOURCE_LAST_PWD=""
    export ENVS_DEV_SOURCE_NAME ENVS_DEV_SOURCE_INJECTED_KEYS ENVS_DEV_SOURCE_LAST_MATCHED ENVS_DEV_SOURCE_LAST_PWD
    _envs_dev_source_precmd
    return 0
  fi

  ENVS_DEV_SOURCE_DUMP_FILE=$(mktemp -t envs-dev-source-dump.XXXXXX)
  # Use `env` for a shell-neutral KEY=VALUE snapshot. bash's `export -p` emits
  # `declare -x KEY="val"`, which the restore grep below would miss; `env` is
  # consistent across zsh / bash / dash / BSD.
  env > "$ENVS_DEV_SOURCE_DUMP_FILE"

  ENVS_DEV_SOURCE_ACTIVE=1
  ENVS_DEV_SOURCE_NAME="$_new_name"
  ENVS_DEV_SOURCE_INJECTED_KEYS=""
  ENVS_DEV_SOURCE_LAST_MATCHED=""
  # PWD cache — empty forces full evaluation on first precmd.
  ENVS_DEV_SOURCE_LAST_PWD=""
  export ENVS_DEV_SOURCE_ACTIVE ENVS_DEV_SOURCE_NAME ENVS_DEV_SOURCE_DUMP_FILE ENVS_DEV_SOURCE_INJECTED_KEYS ENVS_DEV_SOURCE_LAST_MATCHED ENVS_DEV_SOURCE_LAST_PWD

  _envs_dev_source_register_hook
  _envs_dev_source_precmd
}

envs-dev-source-deactivate() {
  if [ -z "${ENVS_DEV_SOURCE_ACTIVE:-}" ]; then
    echo "envs-dev-source: not active" >&2
    return 1
  fi
  _envs_dev_source_restore_keys
  _envs_dev_source_unregister_hook
  if [ -n "${ENVS_DEV_SOURCE_DUMP_FILE:-}" ] && [ -f "$ENVS_DEV_SOURCE_DUMP_FILE" ]; then
    rm -f "$ENVS_DEV_SOURCE_DUMP_FILE"
  fi
  unset ENVS_DEV_SOURCE_ACTIVE ENVS_DEV_SOURCE_NAME ENVS_DEV_SOURCE_DUMP_FILE ENVS_DEV_SOURCE_INJECTED_KEYS ENVS_DEV_SOURCE_LAST_MATCHED ENVS_DEV_SOURCE_LAST_PWD
}

envs-dev-source-status() {
  if [ -z "${ENVS_DEV_SOURCE_ACTIVE:-}" ]; then
    echo "envs-dev-source: inactive"
    return 0
  fi

  echo "envs-dev-source: active"

  if [ -n "${ENVS_DEV_SOURCE_NAME:-}" ]; then
    echo "  name:           ${ENVS_DEV_SOURCE_NAME}"
  else
    echo "  name:           (empty)"
  fi

  if [ -n "${ENVS_DEV_SOURCE_LAST_MATCHED:-}" ]; then
    echo "  matched:        ${ENVS_DEV_SOURCE_LAST_MATCHED}"
  else
    echo "  matched:        (none)"
  fi

  # Normalize injected keys: collapse whitespace, trim leading/trailing spaces.
  _keys_raw="${ENVS_DEV_SOURCE_INJECTED_KEYS:-}"
  if [ -n "$_keys_raw" ]; then
    if [ -n "${ZSH_VERSION:-}" ]; then
      eval 'set -- ${=_keys_raw}'
    else
      set -- $_keys_raw
    fi
    _keys_clean=""
    for _key in "$@"; do
      [ -z "$_key" ] && continue
      if [ -z "$_keys_clean" ]; then
        _keys_clean="$_key"
      else
        _keys_clean="${_keys_clean} ${_key}"
      fi
    done
    if [ -n "$_keys_clean" ]; then
      echo "  injected keys:  ${_keys_clean}"
    else
      echo "  injected keys:  (none)"
    fi
  else
    echo "  injected keys:  (none)"
  fi

  if [ -n "${ENVS_DEV_SOURCE_DUMP_FILE:-}" ]; then
    if [ -f "$ENVS_DEV_SOURCE_DUMP_FILE" ]; then
      echo "  dump file:      ${ENVS_DEV_SOURCE_DUMP_FILE}"
    else
      echo "  dump file:      ${ENVS_DEV_SOURCE_DUMP_FILE} (missing)"
    fi
  else
    echo "  dump file:      (none)"
  fi
}

# Single awk scan over the snapshot file emits one line per injected key:
#   KEY<TAB>1<TAB>VALUE   when the key exists in the snapshot (restore)
#   KEY<TAB>0             when the key was not in the snapshot (unset)
# Subprocess count: exactly 1 regardless of key count.
_envs_dev_source_restore_keys() {
  [ -z "${ENVS_DEV_SOURCE_INJECTED_KEYS:-}" ] && return 0
  [ -z "${ENVS_DEV_SOURCE_DUMP_FILE:-}" ] && return 0
  [ ! -r "$ENVS_DEV_SOURCE_DUMP_FILE" ] && return 0
  _restored=$(awk -F= -v keys="$ENVS_DEV_SOURCE_INJECTED_KEYS" '
    BEGIN {
      n = split(keys, ks, " ")
      for (i = 1; i <= n; i++) {
        if (ks[i] != "") want[ks[i]] = 1
      }
    }
    {
      k = $1
      if (k in want && !(k in seen)) {
        seen[k] = 1
        v = $0
        sub(/^[^=]*=/, "", v)
        printf "%s\t1\t%s\n", k, v
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        k = ks[i]
        if (k != "" && !(k in seen) && !(k in printed)) {
          printed[k] = 1
          printf "%s\t0\n", k
        }
      }
    }
  ' "$ENVS_DEV_SOURCE_DUMP_FILE" 2>/dev/null)
  [ -z "$_restored" ] && return 0
  # Iterate awk output line-by-line via here-doc fed `while read` for portable
  # field splitting (zsh disables unquoted-$var word splitting by default).
  while IFS='	' read -r _k _flag _v; do
    [ -z "$_k" ] && continue
    if [ "$_flag" = "1" ]; then
      export "${_k}=${_v}"
    else
      unset "$_k"
    fi
  done <<EOF
$_restored
EOF
}

_envs_dev_source_precmd() {
  [ -z "${ENVS_DEV_SOURCE_ACTIVE:-}" ] && return 0
  # PWD cache — skip the whole eval while the user stays in the same directory.
  # Trade-off: in-place routing changes (e.g. `git checkout` to a branch that
  # routes differently under the same path), or an external
  # `export ENVS_DEV_SOURCE_NAME=...` outside the public
  # `envs-dev-source-activate` API, won't be picked up until the user cd's
  # away and back. Performance > exactness.
  if [ "${ENVS_DEV_SOURCE_LAST_PWD:-__unset__}" = "$PWD" ]; then
    return 0
  fi
  _envs_dev_source_restore_keys
  ENVS_DEV_SOURCE_INJECTED_KEYS=""

  _envs_dev_bin="${ENVS_DEV_BIN:-envs-dev}"
  _matched=$("$_envs_dev_bin" --source-match "${ENVS_DEV_SOURCE_NAME:-}" 2>/dev/null) || {
    ENVS_DEV_SOURCE_LAST_PWD="$PWD"
    return 0
  }
  [ -z "$_matched" ] && {
    ENVS_DEV_SOURCE_LAST_PWD="$PWD"
    return 0
  }
  [ ! -r "$_matched" ] && {
    ENVS_DEV_SOURCE_LAST_PWD="$PWD"
    return 0
  }

  _new_keys=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      ''|'#'*) continue ;;
      *=*)
        _k="${_line%%=*}"
        export "${_k}=${_line#*=}"
        _new_keys="${_new_keys}${_k} "
        ;;
    esac
  done < "$_matched"

  ENVS_DEV_SOURCE_INJECTED_KEYS="$_new_keys"
  if [ "${ENVS_DEV_SOURCE_LAST_MATCHED:-}" != "$_matched" ]; then
    ENVS_DEV_SOURCE_LAST_MATCHED="$_matched"
  fi
  ENVS_DEV_SOURCE_LAST_PWD="$PWD"
}

_envs_dev_source_register_hook() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    typeset -ga precmd_functions 2>/dev/null
    case " ${precmd_functions[*]:-} " in
      *" _envs_dev_source_precmd "*) ;;
      *) precmd_functions=("${precmd_functions[@]}" _envs_dev_source_precmd) ;;
    esac
  elif [ -n "${BASH_VERSION:-}" ]; then
    case "${PROMPT_COMMAND:-}" in
      *_envs_dev_source_precmd*) ;;
      "") PROMPT_COMMAND="_envs_dev_source_precmd" ;;
      *) PROMPT_COMMAND="_envs_dev_source_precmd;${PROMPT_COMMAND}" ;;
    esac
  fi
}

_envs_dev_source_unregister_hook() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    precmd_functions=("${(@)precmd_functions:#_envs_dev_source_precmd}")
  elif [ -n "${BASH_VERSION:-}" ]; then
    PROMPT_COMMAND="${PROMPT_COMMAND//_envs_dev_source_precmd;/}"
    PROMPT_COMMAND="${PROMPT_COMMAND//_envs_dev_source_precmd/}"
  fi
}

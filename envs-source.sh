# envs-source.sh — virtualenv-style mode for envs CLI (zsh / bash)
# Source this from your shell rc (e.g. ~/.zshrc or ~/.bashrc).
#
# Public functions:
#   envs-source-activate [name]   start source mode; matched .env keys are
#                                  exported into the current shell, and a
#                                  precmd hook re-evaluates them every prompt.
#   envs-source-deactivate         restore the env to its pre-activation state.
#
# Detection: while active, $ENVS_SOURCE_ACTIVE=1 is exported.
# Name:      $ENVS_SOURCE_NAME holds the current routing name ("" for empty).

envs-source-activate() {
  _new_name="${1:-}"

  # Already active: switch routing in place (virtualenv-style, not nested).
  if [ -n "${ENVS_SOURCE_ACTIVE:-}" ]; then
    _envs_source_restore_keys
    ENVS_SOURCE_NAME="$_new_name"
    ENVS_SOURCE_INJECTED_KEYS=""
    ENVS_SOURCE_LAST_MATCHED=""
    export ENVS_SOURCE_NAME ENVS_SOURCE_INJECTED_KEYS ENVS_SOURCE_LAST_MATCHED
    _envs_source_precmd
    return 0
  fi

  # Snapshot the current env so deactivate can restore values for keys we touch.
  ENVS_SOURCE_DUMP_FILE=$(mktemp -t envs-source-dump.XXXXXX) || {
    echo "envs-source: failed to create dump file" >&2
    return 1
  }
  # Use `env` for a shell-neutral KEY=VALUE snapshot. bash's `export -p` emits
  # `declare -x KEY="val"`, which the restore grep below would miss; `env` is
  # consistent across zsh / bash / dash / BSD.
  env > "$ENVS_SOURCE_DUMP_FILE"

  ENVS_SOURCE_ACTIVE=1
  ENVS_SOURCE_NAME="$_new_name"
  ENVS_SOURCE_INJECTED_KEYS=""
  ENVS_SOURCE_LAST_MATCHED=""
  export ENVS_SOURCE_ACTIVE ENVS_SOURCE_NAME ENVS_SOURCE_DUMP_FILE
  export ENVS_SOURCE_INJECTED_KEYS ENVS_SOURCE_LAST_MATCHED

  _envs_source_register_hook
  _envs_source_precmd
}

envs-source-deactivate() {
  if [ -z "${ENVS_SOURCE_ACTIVE:-}" ]; then
    echo "envs-source: not active" >&2
    return 1
  fi
  _envs_source_restore_keys
  _envs_source_unregister_hook
  if [ -n "${ENVS_SOURCE_DUMP_FILE:-}" ] && [ -f "$ENVS_SOURCE_DUMP_FILE" ]; then
    rm -f "$ENVS_SOURCE_DUMP_FILE"
  fi
  unset ENVS_SOURCE_ACTIVE ENVS_SOURCE_NAME ENVS_SOURCE_DUMP_FILE
  unset ENVS_SOURCE_INJECTED_KEYS ENVS_SOURCE_LAST_MATCHED
}

envs-source-status() {
  if [ -z "${ENVS_SOURCE_ACTIVE:-}" ]; then
    echo "envs-source: inactive"
    return 0
  fi

  echo "envs-source: active"

  if [ -n "${ENVS_SOURCE_NAME:-}" ]; then
    echo "  name:           ${ENVS_SOURCE_NAME}"
  else
    echo "  name:           (empty)"
  fi

  if [ -n "${ENVS_SOURCE_LAST_MATCHED:-}" ]; then
    echo "  matched:        ${ENVS_SOURCE_LAST_MATCHED}"
  else
    echo "  matched:        (none)"
  fi

  # Normalize injected keys: collapse whitespace, trim leading/trailing spaces.
  _keys_raw="${ENVS_SOURCE_INJECTED_KEYS:-}"
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

  if [ -n "${ENVS_SOURCE_DUMP_FILE:-}" ]; then
    if [ -f "$ENVS_SOURCE_DUMP_FILE" ]; then
      echo "  dump file:      ${ENVS_SOURCE_DUMP_FILE}"
    else
      echo "  dump file:      ${ENVS_SOURCE_DUMP_FILE} (missing)"
    fi
  else
    echo "  dump file:      (none)"
  fi
}

# Restore the keys we previously injected to their snapshotted values
# (or unset them if they weren't set before activation).
_envs_source_restore_keys() {
  [ -z "${ENVS_SOURCE_INJECTED_KEYS:-}" ] && return 0
  [ -z "${ENVS_SOURCE_DUMP_FILE:-}" ] && return 0
  [ ! -r "$ENVS_SOURCE_DUMP_FILE" ] && return 0
  # Word-split the space-separated key list into positional args.
  # zsh's default (SH_WORD_SPLIT off) does NOT split unquoted $var on whitespace,
  # so without explicit splitting the loop would iterate once with
  # $_key="K1 K2 ..." and unset would fail with "invalid parameter name".
  # In zsh, ${=var} forces splitting; in bash/dash, unquoted $var already splits.
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval 'set -- ${=ENVS_SOURCE_INJECTED_KEYS}'
  else
    set -- $ENVS_SOURCE_INJECTED_KEYS
  fi
  for _key in "$@"; do
    [ -z "$_key" ] && continue
    # Snapshot is `env` output (KEY=VALUE per line), so a simple anchored
    # match is enough. Assign with `export "KEY=VALUE"` directly instead of
    # `eval`ing the line to avoid running shell metacharacters in values.
    _dumpline=$(grep "^${_key}=" "$ENVS_SOURCE_DUMP_FILE" 2>/dev/null | head -1)
    if [ -z "$_dumpline" ]; then
      unset "$_key"
    else
      _value="${_dumpline#*=}"
      export "${_key}=${_value}"
    fi
  done
}

# Re-evaluate routing for the current context and re-export matched keys.
# Called every shell prompt while active.
_envs_source_precmd() {
  [ -z "${ENVS_SOURCE_ACTIVE:-}" ] && return 0
  _envs_source_restore_keys
  ENVS_SOURCE_INJECTED_KEYS=""

  _matched=$(envs --source-match "${ENVS_SOURCE_NAME:-}" 2>/dev/null) || {
    ENVS_SOURCE_LAST_MATCHED=""
    return 0
  }
  [ -z "$_matched" ] && {
    ENVS_SOURCE_LAST_MATCHED=""
    return 0
  }
  [ ! -r "$_matched" ] && {
    ENVS_SOURCE_LAST_MATCHED=""
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

  ENVS_SOURCE_INJECTED_KEYS="$_new_keys"
  if [ "${ENVS_SOURCE_LAST_MATCHED:-}" != "$_matched" ]; then
    echo "envs-source: injected $_matched" >&2
    ENVS_SOURCE_LAST_MATCHED="$_matched"
  fi
}

_envs_source_register_hook() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    # zsh: precmd_functions array
    typeset -ga precmd_functions 2>/dev/null
    case " ${precmd_functions[*]:-} " in
      *" _envs_source_precmd "*) ;;
      *) precmd_functions=("${precmd_functions[@]}" _envs_source_precmd) ;;
    esac
  elif [ -n "${BASH_VERSION:-}" ]; then
    # bash: PROMPT_COMMAND string
    case "${PROMPT_COMMAND:-}" in
      *_envs_source_precmd*) ;;
      "") PROMPT_COMMAND="_envs_source_precmd" ;;
      *) PROMPT_COMMAND="_envs_source_precmd;${PROMPT_COMMAND}" ;;
    esac
  fi
}

_envs_source_unregister_hook() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    precmd_functions=("${(@)precmd_functions:#_envs_source_precmd}")
  elif [ -n "${BASH_VERSION:-}" ]; then
    PROMPT_COMMAND="${PROMPT_COMMAND//_envs_source_precmd;/}"
    PROMPT_COMMAND="${PROMPT_COMMAND//_envs_source_precmd/}"
  fi
}

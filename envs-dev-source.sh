# envs-dev-source.sh — dev variant of envs-source. Calls envs-dev binary, uses ENVS_DEV_SOURCE_* env vars.

envs-dev-source-activate() {
  _new_name="${1:-}"
  _envs_dev_bin="${ENVS_DEV_BIN:-envs-dev}"

  if [ -n "${ENVS_DEV_SOURCE_ACTIVE:-}" ]; then
    _envs_dev_source_restore_keys
    ENVS_DEV_SOURCE_NAME="$_new_name"
    ENVS_DEV_SOURCE_INJECTED_KEYS=""
    ENVS_DEV_SOURCE_LAST_MATCHED=""
    export ENVS_DEV_SOURCE_NAME ENVS_DEV_SOURCE_INJECTED_KEYS ENVS_DEV_SOURCE_LAST_MATCHED
    _envs_dev_source_precmd
    return 0
  fi

  ENVS_DEV_SOURCE_DUMP_FILE=$(mktemp -t envs-dev-source-dump.XXXXXX)
  export -p > "$ENVS_DEV_SOURCE_DUMP_FILE"

  ENVS_DEV_SOURCE_ACTIVE=1
  ENVS_DEV_SOURCE_NAME="$_new_name"
  ENVS_DEV_SOURCE_INJECTED_KEYS=""
  ENVS_DEV_SOURCE_LAST_MATCHED=""
  export ENVS_DEV_SOURCE_ACTIVE ENVS_DEV_SOURCE_NAME ENVS_DEV_SOURCE_DUMP_FILE ENVS_DEV_SOURCE_INJECTED_KEYS ENVS_DEV_SOURCE_LAST_MATCHED

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
  unset ENVS_DEV_SOURCE_ACTIVE ENVS_DEV_SOURCE_NAME ENVS_DEV_SOURCE_DUMP_FILE ENVS_DEV_SOURCE_INJECTED_KEYS ENVS_DEV_SOURCE_LAST_MATCHED
}

_envs_dev_source_restore_keys() {
  [ -z "${ENVS_DEV_SOURCE_INJECTED_KEYS:-}" ] && return 0
  [ -z "${ENVS_DEV_SOURCE_DUMP_FILE:-}" ] && return 0
  [ ! -r "$ENVS_DEV_SOURCE_DUMP_FILE" ] && return 0
  # Word-split the space-separated key list into positional args.
  # zsh's default (SH_WORD_SPLIT off) does NOT split unquoted $var on whitespace,
  # so without explicit splitting the loop would iterate once with
  # $_key="K1 K2 ..." and unset would fail with "invalid parameter name".
  # In zsh, ${=var} forces splitting; in bash/dash, unquoted $var already splits.
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval 'set -- ${=ENVS_DEV_SOURCE_INJECTED_KEYS}'
  else
    set -- $ENVS_DEV_SOURCE_INJECTED_KEYS
  fi
  for _key in "$@"; do
    [ -z "$_key" ] && continue
    _dumpline=$(grep -E "^(export[[:space:]]+)?${_key}=" "$ENVS_DEV_SOURCE_DUMP_FILE" 2>/dev/null | head -1)
    if [ -z "$_dumpline" ]; then
      unset "$_key"
    else
      eval "$_dumpline"
    fi
  done
}

_envs_dev_source_precmd() {
  [ -z "${ENVS_DEV_SOURCE_ACTIVE:-}" ] && return 0
  _envs_dev_source_restore_keys
  ENVS_DEV_SOURCE_INJECTED_KEYS=""

  _envs_dev_bin="${ENVS_DEV_BIN:-envs-dev}"
  _matched=$("$_envs_dev_bin" --source-match "${ENVS_DEV_SOURCE_NAME:-}" 2>/dev/null) || return 0
  [ -z "$_matched" ] && return 0
  [ ! -r "$_matched" ] && return 0

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
    echo "envs-dev-source: injected $_matched" >&2
    ENVS_DEV_SOURCE_LAST_MATCHED="$_matched"
  fi
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

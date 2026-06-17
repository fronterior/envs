# envs-source.fish — virtualenv-style mode for envs CLI (fish shell)
# Source this from your fish config (e.g. ~/.config/fish/config.fish).
#
# Public functions:
#   envs-source-activate [name]   start source mode; matched .env keys are
#                                  exported into the current shell, and a
#                                  fish_prompt event handler re-evaluates them.
#   envs-source-deactivate         restore the env to its pre-activation state.

function envs-source-activate
    set -l _new_name ""
    if test (count $argv) -ge 1
        set _new_name $argv[1]
    end

    # Already active: switch routing in place (virtualenv-style, not nested).
    if set -q ENVS_SOURCE_ACTIVE
        _envs_source_restore_keys
        set -gx ENVS_SOURCE_NAME "$_new_name"
        set -gx ENVS_SOURCE_INJECTED_KEYS ""
        set -gx ENVS_SOURCE_LAST_MATCHED ""
        _envs_source_precmd
        return 0
    end

    set -l _dump (mktemp -t envs-source-dump.XXXXXX)
    if test -z "$_dump"
        echo "envs-source: failed to create dump file" >&2
        return 1
    end
    env > $_dump

    set -gx ENVS_SOURCE_DUMP_FILE $_dump
    set -gx ENVS_SOURCE_ACTIVE 1
    set -gx ENVS_SOURCE_NAME "$_new_name"
    set -gx ENVS_SOURCE_INJECTED_KEYS ""
    set -gx ENVS_SOURCE_LAST_MATCHED ""

    _envs_source_precmd
end

function envs-source-deactivate
    if not set -q ENVS_SOURCE_ACTIVE
        echo "envs-source: not active" >&2
        return 1
    end
    _envs_source_restore_keys
    if test -n "$ENVS_SOURCE_DUMP_FILE" -a -f "$ENVS_SOURCE_DUMP_FILE"
        rm -f $ENVS_SOURCE_DUMP_FILE
    end
    set -e ENVS_SOURCE_ACTIVE
    set -e ENVS_SOURCE_NAME
    set -e ENVS_SOURCE_DUMP_FILE
    set -e ENVS_SOURCE_INJECTED_KEYS
    set -e ENVS_SOURCE_LAST_MATCHED
end

function _envs_source_restore_keys
    if not set -q ENVS_SOURCE_INJECTED_KEYS
        return 0
    end
    if test -z "$ENVS_SOURCE_INJECTED_KEYS"
        return 0
    end
    if not set -q ENVS_SOURCE_DUMP_FILE
        return 0
    end
    if test ! -r "$ENVS_SOURCE_DUMP_FILE"
        return 0
    end
    for _key in (string split ' ' -- $ENVS_SOURCE_INJECTED_KEYS)
        if test -z "$_key"
            continue
        end
        set -l _dumpline (grep -E "^$_key=" "$ENVS_SOURCE_DUMP_FILE" | head -1)
        if test -z "$_dumpline"
            set -e $_key
        else
            # Strip "KEY=" prefix to get the value (handles values containing '=').
            set -l _prefix_len (math (string length -- "$_key") + 1)
            set -l _val (string sub -s (math $_prefix_len + 1) -- "$_dumpline")
            set -gx $_key "$_val"
        end
    end
end

function _envs_source_precmd --on-event fish_prompt
    if not set -q ENVS_SOURCE_ACTIVE
        return 0
    end
    _envs_source_restore_keys
    set -gx ENVS_SOURCE_INJECTED_KEYS ""

    set -l _matched (envs --source-match "$ENVS_SOURCE_NAME" 2>/dev/null)
    if test -z "$_matched"
        set -gx ENVS_SOURCE_LAST_MATCHED ""
        return 0
    end
    if test ! -r "$_matched"
        set -gx ENVS_SOURCE_LAST_MATCHED ""
        return 0
    end

    set -l _new_keys ""
    while read -l _line
        switch "$_line"
            case '' '#*'
                continue
        end
        if string match -q '*=*' -- "$_line"
            set -l _k (string split -m 1 '=' -- "$_line")[1]
            set -l _v (string split -m 1 '=' -- "$_line")[2]
            set -gx $_k "$_v"
            set _new_keys "$_new_keys$_k "
        end
    end < $_matched

    set -gx ENVS_SOURCE_INJECTED_KEYS "$_new_keys"
    if test "$ENVS_SOURCE_LAST_MATCHED" != "$_matched"
        echo "envs-source: injected $_matched" >&2
        set -gx ENVS_SOURCE_LAST_MATCHED "$_matched"
    end
end

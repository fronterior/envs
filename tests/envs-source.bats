#!/usr/bin/env bats
# tests/envs-source.bats — cases for envs-source.sh (prod variant).
# Each shell-spawned subshell runs an end-to-end script and prints assertion
# lines like "KEY=value" that we grep.

load helpers/isolate

setup() {
  isolate_setup
}

teardown() {
  isolate_teardown
}

# ----- zsh -----

@test "zsh: source registers activate/deactivate/precmd functions" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    typeset -f envs-source-activate >/dev/null && echo HAS_ACTIVATE
    typeset -f envs-source-deactivate >/dev/null && echo HAS_DEACTIVATE
    typeset -f _envs_source_precmd >/dev/null && echo HAS_PRECMD
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"HAS_ACTIVATE"* ]]
  [[ "$output" == *"HAS_DEACTIVATE"* ]]
  [[ "$output" == *"HAS_PRECMD"* ]]
}

@test "zsh: activate dev exports all matched keys" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    echo KEY_A=\$KEY_A
    echo KEY_B=\$KEY_B
    echo KEY_C=\$KEY_C
    echo ACTIVE=\$ENVS_SOURCE_ACTIVE
    echo NAME=\$ENVS_SOURCE_NAME
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=devA"* ]]
  [[ "$output" == *"KEY_B=devB"* ]]
  [[ "$output" == *"KEY_C=devC"* ]]
  [[ "$output" == *"ACTIVE=1"* ]]
  [[ "$output" == *"NAME=dev"* ]]
}

@test "zsh: cd to non-matching dir then precmd unsets all keys (word-split regression)" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    cd '$REPO_DIR_OTHER'
    _envs_source_precmd
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
}

@test "zsh: cd to other matching dir (same name) swaps keys via precmd" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    cd '$REPO_DIR_DEV2'
    _envs_source_precmd
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
    echo KEY_D=\${KEY_D:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=dev2A"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
  [[ "$output" == *"KEY_D=dev2D"* ]]
}

@test "zsh: re-activate with different name switches routing in place" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    cd '$REPO_DIR_PROD'
    envs-source-activate prod
    echo NAME=\$ENVS_SOURCE_NAME
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_D=\${KEY_D:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAME=prod"* ]]
  [[ "$output" == *"KEY_A=prodA"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_D=prodD"* ]]
}

@test "zsh: re-activate is in-place (not nested), single dump file across switch" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    _dump1=\$ENVS_SOURCE_DUMP_FILE
    cd '$REPO_DIR_PROD'
    envs-source-activate prod
    _dump2=\$ENVS_SOURCE_DUMP_FILE
    if [ \"\$_dump1\" = \"\$_dump2\" ]; then echo DUMP_SAME; else echo DUMP_DIFF; fi
    echo ACTIVE=\$ENVS_SOURCE_ACTIVE
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"DUMP_SAME"* ]]
  [[ "$output" == *"ACTIVE=1"* ]]
}

@test "zsh: deactivate restores environment and unsets bookkeeping vars" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    envs-source-deactivate
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
    echo ACTIVE=\${ENVS_SOURCE_ACTIVE:-UNSET}
    echo NAME=\${ENVS_SOURCE_NAME:-UNSET}
    echo DUMP=\${ENVS_SOURCE_DUMP_FILE:-UNSET}
    echo INJ=\${ENVS_SOURCE_INJECTED_KEYS:-UNSET}
    echo LAST=\${ENVS_SOURCE_LAST_MATCHED:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
  [[ "$output" == *"ACTIVE=UNSET"* ]]
  [[ "$output" == *"NAME=UNSET"* ]]
  [[ "$output" == *"DUMP=UNSET"* ]]
  [[ "$output" == *"INJ=UNSET"* ]]
  [[ "$output" == *"LAST=UNSET"* ]]
}

@test "zsh: deactivate restores prior value of overlapping key" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    export KEY_A=preexisting
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    echo MID=\$KEY_A
    envs-source-deactivate
    echo POST=\$KEY_A
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MID=devA"* ]]
  [[ "$output" == *"POST=preexisting"* ]]
}

@test "zsh: status shows 'inactive' when not active" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    envs-source-status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"inactive"* ]]
}

@test "zsh: cd to non-matching dir restores pre-existing exported var (snapshot regression)" {
  # Core regression for the shell-neutral snapshot fix. A user-exported var
  # that the matched .env overrides must restore to its original value when
  # routing stops matching — not get unset. Catches both: (a) snapshot grep
  # missing bash's `declare -x` form, (b) overly broad `unset` on cd-away.
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    export KEY_A=preexisting
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    echo MID=\$KEY_A
    cd '$REPO_DIR_OTHER'
    _envs_source_precmd
    echo POST=\${KEY_A:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MID=devA"* ]]
  [[ "$output" == *"POST=preexisting"* ]]
}

@test "zsh: status shows name/matched/injected keys/dump file when active" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    envs-source-status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"active"* ]]
  [[ "$output" == *"name:"* ]]
  [[ "$output" == *"dev"* ]]
  [[ "$output" == *"matched:"* ]]
  [[ "$output" == *".env.dev"* ]]
  [[ "$output" == *"injected keys:"* ]]
  [[ "$output" == *"KEY_A"* ]]
  [[ "$output" == *"KEY_B"* ]]
  [[ "$output" == *"KEY_C"* ]]
  [[ "$output" == *"dump file:"* ]]
}

# ----- bash -----

@test "bash: source registers activate/deactivate/precmd functions" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    declare -f envs-source-activate >/dev/null && echo HAS_ACTIVATE
    declare -f envs-source-deactivate >/dev/null && echo HAS_DEACTIVATE
    declare -f _envs_source_precmd >/dev/null && echo HAS_PRECMD
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"HAS_ACTIVATE"* ]]
  [[ "$output" == *"HAS_DEACTIVATE"* ]]
  [[ "$output" == *"HAS_PRECMD"* ]]
}

@test "bash: activate dev exports all matched keys" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    echo KEY_A=\$KEY_A
    echo KEY_B=\$KEY_B
    echo KEY_C=\$KEY_C
    echo ACTIVE=\$ENVS_SOURCE_ACTIVE
    echo NAME=\$ENVS_SOURCE_NAME
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=devA"* ]]
  [[ "$output" == *"KEY_B=devB"* ]]
  [[ "$output" == *"KEY_C=devC"* ]]
  [[ "$output" == *"ACTIVE=1"* ]]
  [[ "$output" == *"NAME=dev"* ]]
}

@test "bash: cd to non-matching dir then precmd unsets all keys" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    cd '$REPO_DIR_OTHER'
    _envs_source_precmd
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
}

@test "bash: cd to other matching dir (same name) swaps keys via precmd" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    cd '$REPO_DIR_DEV2'
    _envs_source_precmd
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
    echo KEY_D=\${KEY_D:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=dev2A"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
  [[ "$output" == *"KEY_D=dev2D"* ]]
}

@test "bash: re-activate with different name switches routing in place" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    cd '$REPO_DIR_PROD'
    envs-source-activate prod
    echo NAME=\$ENVS_SOURCE_NAME
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_D=\${KEY_D:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAME=prod"* ]]
  [[ "$output" == *"KEY_A=prodA"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_D=prodD"* ]]
}

@test "bash: re-activate is in-place" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    _dump1=\$ENVS_SOURCE_DUMP_FILE
    cd '$REPO_DIR_PROD'
    envs-source-activate prod
    _dump2=\$ENVS_SOURCE_DUMP_FILE
    if [ \"\$_dump1\" = \"\$_dump2\" ]; then echo DUMP_SAME; else echo DUMP_DIFF; fi
    echo ACTIVE=\$ENVS_SOURCE_ACTIVE
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"DUMP_SAME"* ]]
  [[ "$output" == *"ACTIVE=1"* ]]
}

@test "bash: deactivate restores environment and unsets bookkeeping vars" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    envs-source-deactivate
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
    echo ACTIVE=\${ENVS_SOURCE_ACTIVE:-UNSET}
    echo NAME=\${ENVS_SOURCE_NAME:-UNSET}
    echo DUMP=\${ENVS_SOURCE_DUMP_FILE:-UNSET}
    echo INJ=\${ENVS_SOURCE_INJECTED_KEYS:-UNSET}
    echo LAST=\${ENVS_SOURCE_LAST_MATCHED:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
  [[ "$output" == *"ACTIVE=UNSET"* ]]
  [[ "$output" == *"NAME=UNSET"* ]]
  [[ "$output" == *"DUMP=UNSET"* ]]
  [[ "$output" == *"INJ=UNSET"* ]]
  [[ "$output" == *"LAST=UNSET"* ]]
}

@test "bash: deactivate restores prior value of overlapping key" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    export KEY_A=preexisting
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    echo MID=\$KEY_A
    envs-source-deactivate
    echo POST=\$KEY_A
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MID=devA"* ]]
  [[ "$output" == *"POST=preexisting"* ]]
}

@test "bash: status shows 'inactive' when not active" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    envs-source-status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"inactive"* ]]
}

@test "bash: cd to non-matching dir restores pre-existing exported var (snapshot regression)" {
  # Core regression for the shell-neutral snapshot fix. A user-exported var
  # that the matched .env overrides must restore to its original value when
  # routing stops matching — not get unset. Catches both: (a) snapshot grep
  # missing bash's `declare -x` form, (b) overly broad `unset` on cd-away.
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    export KEY_A=preexisting
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    echo MID=\$KEY_A
    cd '$REPO_DIR_OTHER'
    _envs_source_precmd
    echo POST=\${KEY_A:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MID=devA"* ]]
  [[ "$output" == *"POST=preexisting"* ]]
}

@test "bash: status shows name/matched/injected keys/dump file when active" {
  setup_sh="$(print_sh_setup envs-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-source-activate dev
    envs-source-status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"active"* ]]
  [[ "$output" == *"name:"* ]]
  [[ "$output" == *"dev"* ]]
  [[ "$output" == *"matched:"* ]]
  [[ "$output" == *".env.dev"* ]]
  [[ "$output" == *"injected keys:"* ]]
  [[ "$output" == *"KEY_A"* ]]
  [[ "$output" == *"KEY_B"* ]]
  [[ "$output" == *"KEY_C"* ]]
  [[ "$output" == *"dump file:"* ]]
}

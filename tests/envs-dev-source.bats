#!/usr/bin/env bats
# tests/envs-dev-source.bats — cases for envs-dev-source.sh (dev variant).
# Differences from prod: uses ENVS_DEV_* env vars, calls $ENVS_DEV_BIN (default
# envs-dev), and adds envs-dev-source-status.

load helpers/isolate

setup() {
  isolate_setup
}

teardown() {
  isolate_teardown
}

# ----- zsh -----

@test "zsh: dev source registers activate/deactivate/status/precmd" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    typeset -f envs-dev-source-activate >/dev/null && echo HAS_ACTIVATE
    typeset -f envs-dev-source-deactivate >/dev/null && echo HAS_DEACTIVATE
    typeset -f envs-dev-source-status >/dev/null && echo HAS_STATUS
    typeset -f _envs_dev_source_precmd >/dev/null && echo HAS_PRECMD
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"HAS_ACTIVATE"* ]]
  [[ "$output" == *"HAS_DEACTIVATE"* ]]
  [[ "$output" == *"HAS_STATUS"* ]]
  [[ "$output" == *"HAS_PRECMD"* ]]
}

@test "zsh: dev activate exports all matched keys via ENVS_DEV_BIN" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    echo KEY_A=\$KEY_A
    echo KEY_B=\$KEY_B
    echo KEY_C=\$KEY_C
    echo ACTIVE=\$ENVS_DEV_SOURCE_ACTIVE
    echo NAME=\$ENVS_DEV_SOURCE_NAME
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=devA"* ]]
  [[ "$output" == *"KEY_B=devB"* ]]
  [[ "$output" == *"KEY_C=devC"* ]]
  [[ "$output" == *"ACTIVE=1"* ]]
  [[ "$output" == *"NAME=dev"* ]]
}

@test "zsh: dev cd to non-matching dir then precmd unsets all keys" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    cd '$REPO_DIR_OTHER'
    _envs_dev_source_precmd
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
}

@test "zsh: dev cd to other matching dir (same name) swaps keys via precmd" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    cd '$REPO_DIR_DEV2'
    _envs_dev_source_precmd
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

@test "zsh: dev re-activate with different name switches routing in place" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    cd '$REPO_DIR_PROD'
    envs-dev-source-activate prod
    echo NAME=\$ENVS_DEV_SOURCE_NAME
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

@test "zsh: dev deactivate restores environment and unsets bookkeeping vars" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    envs-dev-source-deactivate
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
    echo ACTIVE=\${ENVS_DEV_SOURCE_ACTIVE:-UNSET}
    echo NAME=\${ENVS_DEV_SOURCE_NAME:-UNSET}
    echo DUMP=\${ENVS_DEV_SOURCE_DUMP_FILE:-UNSET}
    echo INJ=\${ENVS_DEV_SOURCE_INJECTED_KEYS:-UNSET}
    echo LAST=\${ENVS_DEV_SOURCE_LAST_MATCHED:-UNSET}
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

@test "zsh: dev status shows 'inactive' when not active" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    envs-dev-source-status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"inactive"* ]]
}

@test "zsh: dev status shows name/matched/injected keys/dump file when active" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run zsh -fc "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    envs-dev-source-status
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

@test "bash: dev source registers activate/deactivate/status/precmd" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    declare -f envs-dev-source-activate >/dev/null && echo HAS_ACTIVATE
    declare -f envs-dev-source-deactivate >/dev/null && echo HAS_DEACTIVATE
    declare -f envs-dev-source-status >/dev/null && echo HAS_STATUS
    declare -f _envs_dev_source_precmd >/dev/null && echo HAS_PRECMD
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"HAS_ACTIVATE"* ]]
  [[ "$output" == *"HAS_DEACTIVATE"* ]]
  [[ "$output" == *"HAS_STATUS"* ]]
  [[ "$output" == *"HAS_PRECMD"* ]]
}

@test "bash: dev activate exports all matched keys" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    echo KEY_A=\$KEY_A
    echo KEY_B=\$KEY_B
    echo KEY_C=\$KEY_C
    echo ACTIVE=\$ENVS_DEV_SOURCE_ACTIVE
    echo NAME=\$ENVS_DEV_SOURCE_NAME
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=devA"* ]]
  [[ "$output" == *"KEY_B=devB"* ]]
  [[ "$output" == *"KEY_C=devC"* ]]
  [[ "$output" == *"ACTIVE=1"* ]]
  [[ "$output" == *"NAME=dev"* ]]
}

@test "bash: dev cd to non-matching dir then precmd unsets all keys" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    cd '$REPO_DIR_OTHER'
    _envs_dev_source_precmd
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
}

@test "bash: dev cd to other matching dir (same name) swaps keys via precmd" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    cd '$REPO_DIR_DEV2'
    _envs_dev_source_precmd
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

@test "bash: dev re-activate with different name switches routing in place" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    cd '$REPO_DIR_PROD'
    envs-dev-source-activate prod
    echo NAME=\$ENVS_DEV_SOURCE_NAME
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

@test "bash: dev deactivate restores environment and unsets bookkeeping vars" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    envs-dev-source-deactivate
    echo KEY_A=\${KEY_A:-UNSET}
    echo KEY_B=\${KEY_B:-UNSET}
    echo KEY_C=\${KEY_C:-UNSET}
    echo ACTIVE=\${ENVS_DEV_SOURCE_ACTIVE:-UNSET}
    echo NAME=\${ENVS_DEV_SOURCE_NAME:-UNSET}
    echo DUMP=\${ENVS_DEV_SOURCE_DUMP_FILE:-UNSET}
    echo INJ=\${ENVS_DEV_SOURCE_INJECTED_KEYS:-UNSET}
    echo LAST=\${ENVS_DEV_SOURCE_LAST_MATCHED:-UNSET}
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

@test "bash: dev status shows 'inactive' when not active" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    envs-dev-source-status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"inactive"* ]]
}

@test "bash: dev status shows name/matched/injected keys/dump file when active" {
  setup_sh="$(print_sh_setup envs-dev-source.sh)"
  run bash -c "
    $setup_sh
    cd '$REPO_DIR_DEV'
    envs-dev-source-activate dev
    envs-dev-source-status
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

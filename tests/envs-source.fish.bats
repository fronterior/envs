#!/usr/bin/env bats
# tests/envs-source.fish.bats — cases for envs-source.fish (fish shell).
# bats itself is bash; we spawn `fish --no-config -c '...'` per case so the
# user's fish config (~/.config/fish) is never read.

load helpers/isolate

setup() {
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish not installed"
  fi
  isolate_setup
}

teardown() {
  isolate_teardown
}

@test "fish: source registers activate/deactivate/precmd functions" {
  setup_fish="$(print_fish_setup)"
  run fish --no-config -c "
    $setup_fish
    functions -q envs-source-activate; and echo HAS_ACTIVATE
    functions -q envs-source-deactivate; and echo HAS_DEACTIVATE
    functions -q _envs_source_precmd; and echo HAS_PRECMD
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"HAS_ACTIVATE"* ]]
  [[ "$output" == *"HAS_DEACTIVATE"* ]]
  [[ "$output" == *"HAS_PRECMD"* ]]
}

@test "fish: activate dev exports all matched keys" {
  setup_fish="$(print_fish_setup)"
  run fish --no-config -c "
    $setup_fish
    cd $REPO_DIR_DEV
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

@test "fish: cd to non-matching dir then emit fish_prompt unsets all keys" {
  setup_fish="$(print_fish_setup)"
  run fish --no-config -c "
    $setup_fish
    cd $REPO_DIR_DEV
    envs-source-activate dev
    cd $REPO_DIR_OTHER
    emit fish_prompt
    if set -q KEY_A
        echo KEY_A=\$KEY_A
    else
        echo KEY_A=UNSET
    end
    if set -q KEY_B
        echo KEY_B=\$KEY_B
    else
        echo KEY_B=UNSET
    end
    if set -q KEY_C
        echo KEY_C=\$KEY_C
    else
        echo KEY_C=UNSET
    end
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
}

@test "fish: cd to other matching dir (same name) swaps keys via emit fish_prompt" {
  setup_fish="$(print_fish_setup)"
  run fish --no-config -c "
    $setup_fish
    cd $REPO_DIR_DEV
    envs-source-activate dev
    cd $REPO_DIR_DEV2
    emit fish_prompt
    echo KEY_A=\$KEY_A
    if set -q KEY_B
        echo KEY_B=\$KEY_B
    else
        echo KEY_B=UNSET
    end
    if set -q KEY_C
        echo KEY_C=\$KEY_C
    else
        echo KEY_C=UNSET
    end
    echo KEY_D=\$KEY_D
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=dev2A"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
  [[ "$output" == *"KEY_D=dev2D"* ]]
}

@test "fish: re-activate with different name switches routing in place" {
  setup_fish="$(print_fish_setup)"
  run fish --no-config -c "
    $setup_fish
    cd $REPO_DIR_DEV
    envs-source-activate dev
    cd $REPO_DIR_PROD
    envs-source-activate prod
    echo NAME=\$ENVS_SOURCE_NAME
    echo KEY_A=\$KEY_A
    if set -q KEY_B
        echo KEY_B=\$KEY_B
    else
        echo KEY_B=UNSET
    end
    echo KEY_D=\$KEY_D
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAME=prod"* ]]
  [[ "$output" == *"KEY_A=prodA"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_D=prodD"* ]]
}

@test "fish: deactivate restores environment and unsets bookkeeping vars" {
  setup_fish="$(print_fish_setup)"
  run fish --no-config -c "
    $setup_fish
    cd $REPO_DIR_DEV
    envs-source-activate dev
    envs-source-deactivate
    if set -q KEY_A
        echo KEY_A=\$KEY_A
    else
        echo KEY_A=UNSET
    end
    if set -q KEY_B
        echo KEY_B=\$KEY_B
    else
        echo KEY_B=UNSET
    end
    if set -q KEY_C
        echo KEY_C=\$KEY_C
    else
        echo KEY_C=UNSET
    end
    if set -q ENVS_SOURCE_ACTIVE
        echo ACTIVE=\$ENVS_SOURCE_ACTIVE
    else
        echo ACTIVE=UNSET
    end
    if set -q ENVS_SOURCE_NAME
        echo NAME=\$ENVS_SOURCE_NAME
    else
        echo NAME=UNSET
    end
    if set -q ENVS_SOURCE_DUMP_FILE
        echo DUMP=\$ENVS_SOURCE_DUMP_FILE
    else
        echo DUMP=UNSET
    end
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A=UNSET"* ]]
  [[ "$output" == *"KEY_B=UNSET"* ]]
  [[ "$output" == *"KEY_C=UNSET"* ]]
  [[ "$output" == *"ACTIVE=UNSET"* ]]
  [[ "$output" == *"NAME=UNSET"* ]]
  [[ "$output" == *"DUMP=UNSET"* ]]
}

@test "fish: deactivate restores prior value of overlapping key" {
  setup_fish="$(print_fish_setup)"
  run fish --no-config -c "
    $setup_fish
    set -gx KEY_A preexisting
    cd $REPO_DIR_DEV
    envs-source-activate dev
    echo MID=\$KEY_A
    envs-source-deactivate
    echo POST=\$KEY_A
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MID=devA"* ]]
  [[ "$output" == *"POST=preexisting"* ]]
}

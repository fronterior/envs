#!/usr/bin/env bats
# tests/envs-routing.bats — end-to-end routing for the `envs <name> <cmd>` binary.
#
# Each test is a declarative scenario (see tests/helpers/routing.bash):
#   * an .env, a routing config, and a directory tree are written under an
#     isolated tmp HOME,
#   * the REAL compiled binary is run from a real cwd,
#   * the value it injected into the command is asserted.
#
# Covers the binary's headline path (match rule -> load .env -> exec command
# with env injected) across every current_dir matching form, multi-condition
# AND, env_name selection, first-match-wins, comments, and path interpolation.

load helpers/routing

setup() {
  routing_require_bin
}

teardown() {
  routing_teardown
}

@test "current_dir bare 'frontends' is a substring match — matches anywhere in the path" {
  routing_case "TEST=true" "<current_dir:frontends>test:.env" "
    - ~
      - Dev
        - frontends
      - frontends
      - work
        - frontends-app
      - other
  "
  assert_var Dev/frontends    test TEST true
  assert_var frontends        test TEST true
  assert_var work/frontends-app test TEST true
  assert_var other            test TEST ""
}

@test "current_dir 'Dev/frontends' multi-segment substring — distinguishes the two dirs" {
  routing_case "TEST=true" "<current_dir:Dev/frontends>test:.env" "
    - ~
      - Dev
        - frontends
      - frontends
  "
  assert_var Dev/frontends test TEST true
  assert_var frontends     test TEST ""
}

@test "current_dir matching is ASCII case-insensitive ('dev/frontends' matches '.../Dev/frontends')" {
  routing_case "TEST=true" "<current_dir:dev/frontends>test:.env" "
    - ~
      - Dev
        - frontends
      - frontends
  "
  assert_var Dev/frontends test TEST true
  assert_var frontends     test TEST ""
}

@test "current_dir case-insensitive on the bare form too ('FRONTENDS' matches 'frontends')" {
  routing_case "TEST=true" "<current_dir:FRONTENDS>test:.env" "
    - ~
      - Dev
        - frontends
  "
  assert_var Dev/frontends test TEST true
}

@test "current_dir '*/frontends' matches the last segment only" {
  routing_case "TEST=true" "<current_dir:*/frontends>test:.env" "
    - ~
      - Dev
        - frontends
          - sub
      - frontends
  "
  assert_var Dev/frontends     test TEST true
  assert_var frontends         test TEST true
  assert_var Dev/frontends/sub test TEST ""
}

@test "current_dir '*/frontends/' accepts a trailing slash (last segment)" {
  routing_case "TEST=true" "<current_dir:*/frontends/>test:.env" "
    - ~
      - Dev
        - frontends
          - sub
  "
  assert_var Dev/frontends     test TEST true
  assert_var Dev/frontends/sub test TEST ""
}

@test "current_dir '*/frontends/*' matches an interior segment only" {
  routing_case "TEST=true" "<current_dir:*/frontends/*>test:.env" "
    - ~
      - Dev
        - frontends
          - sub
  "
  assert_var Dev/frontends/sub test TEST true
  assert_var Dev/frontends     test TEST ""
}

@test "two conditions are AND-ed (both current_dir substrings must be present)" {
  routing_case "TEST=true" "<current_dir:Dev,current_dir:frontends>test:.env" "
    - ~
      - Dev
        - frontends
        - backend
      - x
        - frontends
  "
  assert_var Dev/frontends test TEST true
  assert_var Dev/backend   test TEST ""
  assert_var x/frontends   test TEST ""
}

@test "first matching rule wins (order matters)" {
  routing_case "" "<current_dir:frontends>test:.env.first
<current_dir:Dev>test:.env.second" "
    - ~
      - Dev
        - frontends
        - backend
  "
  cfg_file .env.first  "TEST=first"
  cfg_file .env.second "TEST=second"
  assert_var Dev/frontends test TEST first
  assert_var Dev/backend   test TEST second
}

@test "env_name selects the rule (dev vs prod vs unknown)" {
  routing_case "" "<current_dir:frontends>dev:.env.dev
<current_dir:frontends>prod:.env.prod" "
    - ~
      - Dev
        - frontends
  "
  cfg_file .env.dev  "TEST=devval"
  cfg_file .env.prod "TEST=prodval"
  assert_var Dev/frontends dev   TEST devval
  assert_var Dev/frontends prod  TEST prodval
  assert_var Dev/frontends other TEST ""
}

@test "comment and blank lines in the config are ignored" {
  routing_case "TEST=true" "# leading comment

<current_dir:frontends>test:.env
# trailing comment" "
    - ~
      - Dev
        - frontends
  "
  assert_var Dev/frontends test TEST true
}

@test "path interpolation: <current_dir> resolves to the cwd basename" {
  routing_case "" "test:./<current_dir>/.env" "
    - ~
      - Dev
        - frontends
  "
  cfg_file frontends/.env "TEST=interp"
  assert_var Dev/frontends test TEST interp
}

@test "multiple injected keys all reach the command" {
  routing_case "KEY_A=a
KEY_B=b
KEY_C=c" "<current_dir:frontends>test:.env" "
    - ~
      - Dev
        - frontends
  "
  assert_var Dev/frontends test KEY_A a
  assert_var Dev/frontends test KEY_B b
  assert_var Dev/frontends test KEY_C c
}

@test "no matching rule -> nothing injected, but the command still runs" {
  routing_case "TEST=true" "<current_dir:frontends>test:.env" "
    - ~
      - other
  "
  assert_var other test TEST ""
  run bash -c "cd '$HOME/other' && '$ENVS_BIN' test sh -c 'printf RAN' 2>/dev/null"
  [ "$output" = "RAN" ]
}

@test "unknown condition key (typo) never matches" {
  routing_case "TEST=true" "<rpeo:myapp>test:.env" "
    - ~
      - Dev
        - frontends
  "
  assert_var Dev/frontends test TEST ""
}

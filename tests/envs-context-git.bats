#!/usr/bin/env bats
# tests/envs-context-git.bats — e2e for the git-derived context keywords
# (repo / org / branch), including the worktree case, against the REAL binary.
#
# These use real `git` (git_repo / git_worktree in helpers/routing.bash) rather
# than hand-written .git fixtures: envs's worktree handling exists precisely to
# parse the layout `git worktree add` produces, so testing against real git is
# the faithful check. git is required — the suite FAILS (not skips) without it.

load helpers/routing

setup() {
  routing_require_bin
  routing_require_git
}

teardown() {
  routing_teardown
}

@test "repo condition matches the origin repo basename" {
  routing_case "TEST=true" "<repo:myapp>test:.env" ""
  git_repo work/myapp "git@github.com:octocat/myapp.git" main
  assert_var work/myapp test TEST true
}

@test "org condition matches the origin org/user segment" {
  routing_case "TEST=true" "<org:octocat>test:.env" ""
  git_repo work/myapp "git@github.com:octocat/myapp.git" main
  assert_var work/myapp test TEST true
}

@test "branch condition matches HEAD's branch" {
  routing_case "TEST=true" "<branch:dev>test:.env" ""
  git_repo work/myapp "git@github.com:octocat/myapp.git" dev
  assert_var work/myapp test TEST true
}

@test "branch condition does not match a different branch" {
  routing_case "TEST=true" "<branch:main>test:.env" ""
  git_repo work/myapp "git@github.com:octocat/myapp.git" dev
  assert_var work/myapp test TEST ""
}

@test "repo + org + branch all resolve inside a linked worktree" {
  routing_case "TEST=true" "<repo:myapp,org:octocat,branch:feature/x>test:.env" ""
  git_worktree main wt feature/x "git@github.com:octocat/myapp.git"
  assert_var wt test TEST true
}

@test "a git condition never matches outside a git repo (empty context value)" {
  routing_case "TEST=true" "<repo:myapp>test:.env" "
    - ~
      - plain
  "
  assert_var plain test TEST ""
}

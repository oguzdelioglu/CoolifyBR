#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
  FIXTURE_DIR="$(copy_repo_cli_fixture)"
}

teardown() {
  teardown_test_tmp
}

@test "cli help shows product commands" {
  run "$FIXTURE_DIR/coolifybr" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"coolifybr <command> [subcommand]"* ]]
  [[ "$output" == *"init job"* ]]
}

@test "cli dispatches nested pull jobs run" {
  run "$FIXTURE_DIR/coolifybr" pull jobs run
  [ "$status" -eq 0 ]
  [ "$output" = "run-jobs-stub" ]
}

@test "cli dispatches init job" {
  run "$FIXTURE_DIR/coolifybr" init job --name app1
  [ "$status" -eq 0 ]
  [[ "$output" == init-job-stub* ]]
}

@test "legacy alias still works" {
  run "$FIXTURE_DIR/coolifybr" pull-verify /tmp/x
  [ "$status" -eq 0 ]
  [[ "$output" == verify-stub* ]]
}

@test "unknown command fails" {
  run "$FIXTURE_DIR/coolifybr" nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command"* ]]
}

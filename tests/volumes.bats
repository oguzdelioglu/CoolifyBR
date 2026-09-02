#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
  # lib/common.sh supplies the log_* helpers volumes.sh calls.
  source "$(repo_path lib/common.sh)"
  source "$(repo_path lib/volumes.sh)"
}

teardown() {
  teardown_test_tmp
}

@test "no exclude patterns means nothing is excluded" {
  EXCLUDE_VOLUME_PATTERNS=()
  run volume_is_excluded some_project_postgres-data
  [ "$status" -ne 0 ]
}

@test "an unset pattern array does not crash under set -u" {
  unset EXCLUDE_VOLUME_PATTERNS
  run volume_is_excluded some_project_postgres-data
  [ "$status" -ne 0 ]
}

@test "a glob matches anywhere in the volume name" {
  EXCLUDE_VOLUME_PATTERNS=('*postgres-data*')
  run volume_is_excluded abc123_postgres-data-prod-v3
  [ "$status" -eq 0 ]
}

@test "a glob anchored at the end does not match a longer name" {
  EXCLUDE_VOLUME_PATTERNS=('*metrics-data')
  run volume_is_excluded proj_metrics-data
  [ "$status" -eq 0 ]
  run volume_is_excluded proj_metrics-data-extra
  [ "$status" -ne 0 ]
}

@test "a volume matching no pattern is kept" {
  EXCLUDE_VOLUME_PATTERNS=('*postgres-data*' '*_logs')
  run volume_is_excluded proj_redis-data
  [ "$status" -ne 0 ]
}

@test "patterns are matched literally, not as substrings" {
  # 'redis' alone must not exclude a volume just because the name contains it;
  # the pattern is a glob over the whole name.
  EXCLUDE_VOLUME_PATTERNS=('redis')
  run volume_is_excluded proj_redis-data
  [ "$status" -ne 0 ]
}

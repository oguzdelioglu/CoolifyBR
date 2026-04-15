#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
  source "$(repo_path scripts/lib/bootstrap.sh)"
}

teardown() {
  teardown_test_tmp
}

@test "bool_is_true accepts common truthy values" {
  run bool_is_true true
  [ "$status" -eq 0 ]
  run bool_is_true YES
  [ "$status" -eq 0 ]
}

@test "bool_is_true rejects falsy values" {
  run bool_is_true false
  [ "$status" -ne 0 ]
}

@test "cron_line_for_job renders expected command" {
  run cron_line_for_job /repo /cfg/job.env /backups/app 3 15
  [ "$status" -eq 0 ]
  [[ "$output" == "15 3 * * * cd /repo && CONFIG_FILE=/cfg/job.env /repo/ops/remote-pull-backup.sh >> /backups/app/logs/cron.log 2>&1" ]]
}

@test "render_job_config includes name and schedule" {
  run render_job_config app1 203.0.113.10 root 22 /root/.ssh/id_ed25519 /srv/backups/app1 4 45
  [ "$status" -eq 0 ]
  [[ "$output" == *'BACKUP_JOB_NAME="app1"'* ]]
  [[ "$output" == *'SCHEDULE_HOUR="4"'* ]]
  [[ "$output" == *'SCHEDULE_MINUTE="45"'* ]]
}

@test "detect_package_manager prefers first available mock" {
  mock_cmd apt-get 'exit 0'
  run detect_package_manager
  [ "$status" -eq 0 ]
  [ "$output" = "apt-get" ]
}

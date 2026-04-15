#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
}

teardown() {
  teardown_test_tmp
}

@test "single-job cron installer writes expected line" {
  local cfg="$TEST_TMPDIR/job.env"
  local crontab="$TEST_TMPDIR/root"
  local script
  local backup_root="$TEST_TMPDIR/backups/app1"
  script="$(repo_path ops/install-remote-pull-cron.sh)"
  cat >"$cfg" <<EOF
BACKUP_JOB_NAME="app1"
LOCAL_BACKUP_ROOT="$backup_root"
SCHEDULE_HOUR="4"
SCHEDULE_MINUTE="20"
EOF
  run env CONFIG_FILE="$cfg" CRON_FILE="$crontab" "$script"
  [ "$status" -eq 0 ]
  grep -q '20 4 \* \* \*' "$crontab"
  [ -d "$backup_root/logs" ]
}

@test "jobs cron installer writes one line per config" {
  local cfgdir="$TEST_TMPDIR/jobs"
  local crontab="$TEST_TMPDIR/root"
  local script
  local backup_root_one="$TEST_TMPDIR/backups/app1"
  local backup_root_two="$TEST_TMPDIR/backups/app2"
  script="$(repo_path ops/install-remote-pull-jobs-cron.sh)"
  mkdir -p "$cfgdir"
  cat >"$cfgdir/app1.env" <<EOF
BACKUP_JOB_NAME="app1"
LOCAL_BACKUP_ROOT="$backup_root_one"
SCHEDULE_HOUR="1"
SCHEDULE_MINUTE="5"
EOF
  cat >"$cfgdir/app2.env" <<EOF
BACKUP_JOB_NAME="app2"
LOCAL_BACKUP_ROOT="$backup_root_two"
SCHEDULE_HOUR="2"
SCHEDULE_MINUTE="10"
EOF
  run env CONFIG_DIR="$cfgdir" CRON_FILE="$crontab" "$script"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$crontab")" -eq 2 ]
  [ -d "$backup_root_one/logs" ]
  [ -d "$backup_root_two/logs" ]
}

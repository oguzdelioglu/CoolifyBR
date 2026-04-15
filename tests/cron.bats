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
  cat >"$cfg" <<'EOF'
BACKUP_JOB_NAME="app1"
LOCAL_BACKUP_ROOT="/srv/backups/app1"
SCHEDULE_HOUR="4"
SCHEDULE_MINUTE="20"
EOF
  run env CONFIG_FILE="$cfg" CRON_FILE="$crontab" /volume1/home/odel/projects/CoolifyBR/ops/install-remote-pull-cron.sh
  [ "$status" -eq 0 ]
  grep -q '20 4 \* \* \*' "$crontab"
}

@test "jobs cron installer writes one line per config" {
  local cfgdir="$TEST_TMPDIR/jobs"
  local crontab="$TEST_TMPDIR/root"
  mkdir -p "$cfgdir"
  cat >"$cfgdir/app1.env" <<'EOF'
BACKUP_JOB_NAME="app1"
LOCAL_BACKUP_ROOT="/srv/backups/app1"
SCHEDULE_HOUR="1"
SCHEDULE_MINUTE="5"
EOF
  cat >"$cfgdir/app2.env" <<'EOF'
BACKUP_JOB_NAME="app2"
LOCAL_BACKUP_ROOT="/srv/backups/app2"
SCHEDULE_HOUR="2"
SCHEDULE_MINUTE="10"
EOF
  run env CONFIG_DIR="$cfgdir" CRON_FILE="$crontab" /volume1/home/odel/projects/CoolifyBR/ops/install-remote-pull-jobs-cron.sh
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$crontab")" -eq 2 ]
}

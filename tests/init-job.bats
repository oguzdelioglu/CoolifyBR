#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
}

teardown() {
  teardown_test_tmp
}

@test "init-job creates config file with provided values" {
  local config_dir="$TEST_TMPDIR/jobs"
  run /volume1/home/odel/projects/CoolifyBR/scripts/init-job.sh \
    --name app1 \
    --host 198.51.100.10 \
    --user deploy \
    --port 2222 \
    --key /keys/app1 \
    --backup-root /srv/backups/app1 \
    --hour 5 \
    --minute 10 \
    --config-dir "$config_dir"
  [ "$status" -eq 0 ]
  [ -f "$config_dir/app1.env" ]
  grep -q 'REMOTE_HOST="198.51.100.10"' "$config_dir/app1.env"
  grep -q 'REMOTE_USER="deploy"' "$config_dir/app1.env"
  grep -q 'SCHEDULE_MINUTE="10"' "$config_dir/app1.env"
}

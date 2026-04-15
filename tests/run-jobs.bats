#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
  mkdir -p "$TEST_TMPDIR/jobs"
  cat >"$TEST_TMPDIR/jobs/app1.env" <<'EOF'
BACKUP_JOB_NAME="app1"
EOF
  cat >"$TEST_TMPDIR/jobs/app2.env" <<'EOF'
BACKUP_JOB_NAME="app2"
EOF
  cat >"$TEST_TMPDIR/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
echo "entry:$CONFIG_FILE"
EOF
  chmod 755 "$TEST_TMPDIR/entrypoint.sh"
}

teardown() {
  teardown_test_tmp
}

@test "run-remote-pull-jobs executes all configs" {
  run env CONFIG_DIR="$TEST_TMPDIR/jobs" ENTRYPOINT="$TEST_TMPDIR/entrypoint.sh" /volume1/home/odel/projects/CoolifyBR/ops/run-remote-pull-jobs.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"entry:$TEST_TMPDIR/jobs/app1.env"* ]]
  [[ "$output" == *"entry:$TEST_TMPDIR/jobs/app2.env"* ]]
}

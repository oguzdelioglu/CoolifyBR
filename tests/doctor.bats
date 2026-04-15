#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
}

teardown() {
  teardown_test_tmp
}

@test "doctor backup-host reports config file state" {
  local cfg="$TEST_TMPDIR/config"
  mkdir -p "$cfg"
  run /volume1/home/odel/projects/CoolifyBR/scripts/doctor.sh --profile backup-host --config-home "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile=backup-host"* ]]
  [[ "$output" == *"config_file=missing"* ]]
}

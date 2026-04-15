#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
}

teardown() {
  teardown_test_tmp
}

@test "installer backup-host scaffolds cli and configs" {
  local bindir="$TEST_TMPDIR/bin-out"
  local cfgdir="$TEST_TMPDIR/config"
  local script
  script="$(repo_path scripts/install.sh)"
  mkdir -p "$bindir" "$cfgdir"
  run "$script" --profile backup-host --install-dir "$bindir" --config-home "$cfgdir" --no-auto-deps
  [ "$status" -eq 0 ]
  [ -L "$bindir/coolifybr" ]
  [ -f "$cfgdir/remote-pull-backup.env" ]
  [ -f "$cfgdir/jobs/example.env" ]
}

@test "installer source-server scaffolds config env" {
  local bindir="$TEST_TMPDIR/bin-out"
  local cfgdir="$TEST_TMPDIR/config"
  local script
  script="$(repo_path scripts/install.sh)"
  mkdir -p "$bindir" "$cfgdir"
  run "$script" --profile source-server --install-dir "$bindir" --config-home "$cfgdir" --no-auto-deps
  [ "$status" -eq 0 ]
  [ -f "$cfgdir/config.env" ]
}

#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
  SNAPROOT="$TEST_TMPDIR/backups"
  mkdir -p "$SNAPROOT/files/20260415T021924Z" "$SNAPROOT/db/20260415T021924Z/database" "$SNAPROOT/docker/20260415T021924Z/volumes"
  echo '{}' > "$SNAPROOT/files/20260415T021924Z/manifest.json"
  echo 'inventory' > "$SNAPROOT/docker/20260415T021924Z/remote-inventory.txt"
  echo 'dbdump' > "$SNAPROOT/db/20260415T021924Z/database/coolify-db.dump"
  tar czf "$TEST_TMPDIR/sample.tar.gz" -C "$TEST_TMPDIR" .
  echo "local_archive=$TEST_TMPDIR/sample.tar.gz" > "$SNAPROOT/files/20260415T021924Z/pull-metadata.txt"
  tar czf "$SNAPROOT/docker/20260415T021924Z/volumes/v1.tar.gz" -C "$TEST_TMPDIR" .
}

teardown() {
  teardown_test_tmp
}

@test "verify script passes for new snapshot format" {
  run /volume1/home/odel/projects/CoolifyBR/ops/verify-remote-pull-backup.sh "$SNAPROOT" 20260415T021924Z
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verification passed"* ]]
}

@test "verify script supports legacy snapshot without metadata" {
  rm -f "$SNAPROOT/files/20260415T021924Z/pull-metadata.txt"
  run /volume1/home/odel/projects/CoolifyBR/ops/verify-remote-pull-backup.sh "$SNAPROOT" 20260415T021924Z
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy snapshot checks"* ]]
}

#!/usr/bin/env bats

load helpers/test_helper.bash

setup() {
  setup_test_tmp
  SNAPROOT="$TEST_TMPDIR/backups"
  ARCHIVE_SRC="$TEST_TMPDIR/archive-src"
  VOLUME_SRC="$TEST_TMPDIR/volume-src"
  mkdir -p "$SNAPROOT/files/20260415T021924Z" "$SNAPROOT/db/20260415T021924Z/database" "$SNAPROOT/docker/20260415T021924Z/volumes"
  mkdir -p "$ARCHIVE_SRC" "$VOLUME_SRC"
  echo '{}' > "$SNAPROOT/files/20260415T021924Z/manifest.json"
  echo 'inventory' > "$SNAPROOT/docker/20260415T021924Z/remote-inventory.txt"
  echo 'dbdump' > "$SNAPROOT/db/20260415T021924Z/database/coolify-db.dump"
  echo 'sample' > "$ARCHIVE_SRC/file.txt"
  echo 'volume' > "$VOLUME_SRC/volume.txt"
  tar czf "$TEST_TMPDIR/sample.tar.gz" -C "$ARCHIVE_SRC" .
  echo "local_archive=$TEST_TMPDIR/sample.tar.gz" > "$SNAPROOT/files/20260415T021924Z/pull-metadata.txt"
  tar czf "$SNAPROOT/docker/20260415T021924Z/volumes/v1.tar.gz" -C "$VOLUME_SRC" .
}

teardown() {
  teardown_test_tmp
}

@test "verify script passes for new snapshot format" {
  local script
  script="$(repo_path ops/verify-remote-pull-backup.sh)"
  run "$script" "$SNAPROOT" 20260415T021924Z
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verification passed"* ]]
}

@test "verify script supports legacy snapshot without metadata" {
  rm -f "$SNAPROOT/files/20260415T021924Z/pull-metadata.txt"
  local script
  script="$(repo_path ops/verify-remote-pull-backup.sh)"
  run "$script" "$SNAPROOT" 20260415T021924Z
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy snapshot checks"* ]]
}

#!/usr/bin/env bats

load helpers/test_helper.bash

# pull_extra_newest lives in a script that runs main() on load, so lift just the
# function out and give it stub transports. ssh_base becomes a local eval and
# scp_from_remote a copy, which is enough to exercise every branch.
setup() {
  setup_test_tmp
  sed -n '/^pull_extra_newest()/,/^}$/p' "$(repo_path ops/remote-pull-backup.sh)" \
    > "$TEST_TMPDIR/fn.sh"

  DB_DIR="$TEST_TMPDIR/db"
  EXTRA_PULL_PROBLEMS=0
  EXTRA_PULL_MAX_AGE_HOURS=48
  EXTRA_PULL_REQUIRED="true"
  REMOTE_TREE="$TEST_TMPDIR/remote"
  mkdir -p "$REMOTE_TREE"

  ensure_dir() { mkdir -p "$1"; }
  log() { :; }
  fail() { echo "fail() was called: $*"; return 99; }
  bool_is_true() { [[ "$1" == "true" ]]; }
  ssh_base() { eval "$1" 2>/dev/null; }
  scp_from_remote() { cp "$1" "$2"; }

  source "$TEST_TMPDIR/fn.sh"
}

teardown() {
  teardown_test_tmp
}

@test "an empty pattern list is a no-op" {
  EXTRA_PULL_NEWEST=""
  pull_extra_newest snap
  [ "$EXTRA_PULL_PROBLEMS" -eq 0 ]
  [ ! -d "$DB_DIR/snap/extra" ]
}

@test "the newest match is the one pulled" {
  echo old > "$REMOTE_TREE/db-1.dump"
  touch -t 202601010000 "$REMOTE_TREE/db-1.dump"
  echo current > "$REMOTE_TREE/db-2.dump"

  EXTRA_PULL_NEWEST="$REMOTE_TREE/db-*.dump"
  pull_extra_newest snap

  [ "$EXTRA_PULL_PROBLEMS" -eq 0 ]
  [ "$(cat "$DB_DIR/snap/extra/db-2.dump")" = "current" ]
  [ ! -f "$DB_DIR/snap/extra/db-1.dump" ]
}

@test "a pattern matching nothing is recorded, not raised immediately" {
  # The caller finishes the run — verification, remote cleanup, retention — and
  # reports at the end, so a missing dump cannot strand an archive on the source.
  EXTRA_PULL_NEWEST="$REMOTE_TREE/absent-*.dump"
  pull_extra_newest snap
  [ "$EXTRA_PULL_PROBLEMS" -eq 1 ]
}

@test "a stale match is flagged but still pulled" {
  echo stale > "$REMOTE_TREE/db-1.dump"
  touch -t 202601010000 "$REMOTE_TREE/db-1.dump"

  EXTRA_PULL_NEWEST="$REMOTE_TREE/db-*.dump"
  pull_extra_newest snap

  [ "$EXTRA_PULL_PROBLEMS" -eq 1 ]
  [ -s "$DB_DIR/snap/extra/db-1.dump" ]
}

@test "a fresh match within the age limit is clean" {
  echo fresh > "$REMOTE_TREE/db-1.dump"
  EXTRA_PULL_NEWEST="$REMOTE_TREE/db-*.dump"
  pull_extra_newest snap
  [ "$EXTRA_PULL_PROBLEMS" -eq 0 ]
}

@test "every pattern is processed, not just the first" {
  # ssh reads stdin, so a `while read` loop calling it would consume the rest of
  # its own pattern list after one pass.
  mkdir -p "$TEST_TMPDIR/other"
  echo a > "$REMOTE_TREE/db-1.dump"
  echo b > "$TEST_TMPDIR/other/blob-1.bin"

  EXTRA_PULL_NEWEST="$REMOTE_TREE/db-*.dump
$TEST_TMPDIR/other/blob-*.bin"
  pull_extra_newest snap

  [ "$EXTRA_PULL_PROBLEMS" -eq 0 ]
  [ -f "$DB_DIR/snap/extra/db-1.dump" ]
  [ -f "$DB_DIR/snap/extra/blob-1.bin" ]
}

@test "blank lines and comments in the pattern list are skipped" {
  echo a > "$REMOTE_TREE/db-1.dump"
  EXTRA_PULL_NEWEST="
# the application database
$REMOTE_TREE/db-*.dump
"
  pull_extra_newest snap
  [ "$EXTRA_PULL_PROBLEMS" -eq 0 ]
  [ "$(ls "$DB_DIR/snap/extra" | wc -l)" -eq 1 ]
}

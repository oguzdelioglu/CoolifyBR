repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

repo_path() {
  printf '%s/%s\n' "$(repo_root)" "$1"
}

setup_test_tmp() {
  export TEST_TMPDIR
  TEST_TMPDIR="$(mktemp -d)"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  mkdir -p "$TEST_TMPDIR/bin"
}

teardown_test_tmp() {
  rm -rf "$TEST_TMPDIR"
}

mock_cmd() {
  local name="$1"
  shift
  cat >"$TEST_TMPDIR/bin/$name" <<EOF
#!/usr/bin/env bash
$*
EOF
  chmod 755 "$TEST_TMPDIR/bin/$name"
}

copy_repo_cli_fixture() {
  local fixture="$TEST_TMPDIR/fixture"
  mkdir -p "$fixture/ops" "$fixture/scripts"
  cp "$(repo_path coolifybr)" "$fixture/coolifybr"
  chmod 755 "$fixture/coolifybr"
  printf '#!/usr/bin/env bash\necho backup-stub "$@"\n' >"$fixture/coolify-backup.sh"
  printf '#!/usr/bin/env bash\necho restore-stub "$@"\n' >"$fixture/coolify-restore.sh"
  printf '#!/usr/bin/env bash\necho install-stub "$@"\n' >"$fixture/scripts/install.sh"
  printf '#!/usr/bin/env bash\necho doctor-stub "$@"\n' >"$fixture/scripts/doctor.sh"
  printf '#!/usr/bin/env bash\necho init-job-stub "$@"\n' >"$fixture/scripts/init-job.sh"
  printf '#!/usr/bin/env bash\necho pull-run-stub "$@"\n' >"$fixture/ops/remote-pull-backup.sh"
  printf '#!/usr/bin/env bash\necho verify-stub "$@"\n' >"$fixture/ops/verify-remote-pull-backup.sh"
  printf '#!/usr/bin/env bash\necho run-jobs-stub "$@"\n' >"$fixture/ops/run-remote-pull-jobs.sh"
  printf '#!/usr/bin/env bash\necho cron-one-stub "$@"\n' >"$fixture/ops/install-remote-pull-cron.sh"
  printf '#!/usr/bin/env bash\necho cron-jobs-stub "$@"\n' >"$fixture/ops/install-remote-pull-jobs-cron.sh"
  chmod 755 "$fixture"/coolify-backup.sh "$fixture"/coolify-restore.sh "$fixture"/scripts/*.sh "$fixture"/ops/*.sh
  printf '%s\n' "$fixture"
}

SHELL := /usr/bin/env bash

.PHONY: test lint syntax ci

test:
	bats tests

lint:
	shellcheck coolifybr scripts/*.sh scripts/lib/*.sh ops/*.sh coolify-*.sh lib/*.sh

syntax:
	find . -type f \( -name '*.sh' -o -name 'coolifybr' -o -name 'coolify-backup.sh' -o -name 'coolify-restore.sh' \) -print0 | xargs -0 -n1 bash -n

ci: lint syntax test

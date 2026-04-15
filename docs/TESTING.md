# Testing

CoolifyBR uses shell-focused test and quality checks.

## Tooling

- `bats-core` for unit and integration-style tests
- `shellcheck` for static analysis
- `bash -n` for syntax validation

## Local commands

```bash
make syntax
make lint
make test
make ci
```

## Test scope

- CLI dispatch and help output
- installer behavior and config scaffolding
- doctor checks
- job config generation
- cron line generation
- snapshot verification for new and legacy formats
- remote pull helper logic via mocks and temp directories

## CI

GitHub Actions runs shellcheck, syntax validation, and the bats suite on every push and pull request.

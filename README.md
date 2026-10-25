# cotest

Background Go tests for Claude Code sessions. While the agent edits, hooks run the tests of the
packages it touched. When the agent says "done", the result is usually ready, and the `Stop` hook
does not let it finish while tests are red or its changed lines are not executed by any test.

## Install

```bash
git clone https://github.com/tggo/cotest
cotest/install.sh /path/to/your/go/repo
```

Requires git, go, jq, perl, python3 (macOS with Homebrew Go has them). The repo must be a git repo
with a `go.mod`. Re-running the installer is safe. Restart Claude Code sessions in the repo afterwards.

The installer:

- copies `cotest.sh` and `guard.sh` into `.claude/cotest/`, creates `cotest.conf` (keeps an existing one);
- writes `./test.sh`, the only way to run tests;
- merges three hooks into `.claude/settings.json`, keeping your other hooks;
- adds `.claude/cotest/status/` and the log to `.gitignore`;
- adds a marked block with test rules to `CLAUDE.md`;
- runs a self-check: first `./test.sh unit`, and confirms the guard blocks `go test`.

## How it works

| Hook | What it does |
|---|---|
| `PostToolUse` on `Write\|Edit\|MultiEdit\|Bash` | starts a detached worker, returns in milliseconds |
| worker | waits 2 s of quiet, hashes every package, tests only stale ones (one `go test -json` per level) |
| `PreToolUse` | blocks direct `go test`/`go vet`, and writes to cotest's own files |
| `Stop` | every affected package green for the current files, and every changed line covered. Sends the agent back up to 3 times |

The cache key of a package is a hash of its files plus its in-module dependencies (`go list -deps`
and git trees, untracked files included). Edit one package and only it and its importers re-run.
Results are kept per hash, so reverting an edit does not re-run anything.

## Usage

```bash
./test.sh                          # everything, from cache where possible
./test.sh unit ./internal/order/...
./test.sh ./internal/order/store_test.go
./test.sh integration ./internal/order -run TestCreate
./test.sh cover                    # changed lines that no test executes
```

The report is grouped per test file. Logs are in `.claude/cotest/status/<level>/<pkg>.log`.
The `integration` level switches on once a `*_test.go` has `//go:build integration`.

Benchmarks may run directly: `go test -run '^$' -bench . ./pkg`.

Coverage is measured from the commit where the session started (the first edit after a green Stop),
so lines the agent commits mid-session are still checked.

## Settings

`.claude/cotest/cotest.conf`, see [cotest.conf.template](cotest.conf.template): extra test flags
(`-race`), environment exports for tests, coverage mode `block|warn|off`, debounce, attempts, global
inputs such as migrations. The agent cannot edit this file: the guard blocks it.

## Limitations

- Go only.
- In a big repo, editing a package imported by everything costs minutes of background CPU.
- A flaky test is detected (failed tests are rerun once) but stays red; the agent is told which.
- Database isolation needs your tests to use `COTEST_RUN_ID` in the database name.
- macOS bash 3.2 compatible; tested on macOS only.

## License

MIT

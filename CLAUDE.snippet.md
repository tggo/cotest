<!-- cotest:start -->
## Tests (cotest)
- Tests run automatically in the background after every edit, and are checked again when you finish
  (Stop hook). Only packages whose files, or in-module dependencies, changed are re-run. The Stop check
  also covers packages that import what you changed.
- Run tests yourself only through `./test.sh`. It returns the cached result for the current files when
  there is one, so it is usually instant:
  - `./test.sh`: everything
  - `./test.sh unit ./internal/<domain>/...`: one level, one domain
  - `./test.sh ./internal/<domain>/<slice>`: one package, all levels
  - `./test.sh path/to/x_test.go`: only the tests declared in that file
  - `./test.sh unit ./pkg -run TestName`: one test
- Green is not enough: when you finish, every line you changed (vs HEAD, non-test `.go`) must be
  executed by some test, or Stop sends you back with the uncovered lines. `./test.sh cover` shows
  them while you work. If a line truly cannot be tested, say so to the human.
- cotest's files (`.claude/cotest/*`, `.claude/settings.json`, `test.sh`) are the human's; a
  hook blocks edits to them.
- Results are reported per test file. A `FLAKY` line means the same files passed and failed on
  different runs; suspect the test, not your change. Logs: `.claude/cotest/status/<level>/<package>.log`,
  history: `.claude/cotest/status/runs.jsonl`.
- Integration tests carry `//go:build integration` and live next to the code they test.
- Do not call `go test` or `go vet` directly; a hook blocks it.
<!-- cotest:end -->

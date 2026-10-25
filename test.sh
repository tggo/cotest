#!/bin/bash
# Run tests through cotest; results are cached per package for the current files.
#   ./test.sh                                       everything
#   ./test.sh unit internal/link/...                one level, one domain
#   ./test.sh internal/link/store/store_test.go     only the tests declared in that file
#   ./test.sh unit internal/link/store -run TestPutGet
exec "$(dirname "$0")/.claude/cotest/cotest.sh" test "$@"

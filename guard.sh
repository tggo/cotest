#!/bin/bash
# PreToolUse guard for test-battery.
#  - Bash: send the agent to ./test.sh instead of running go test/vet directly.
#  - Any tool: the battery's own scripts, settings and hook registration are the human's, not the agent's.
in=$(cat)
cmd=$(echo "$in" | jq -r '.tool_input.command // empty')
file=$(echo "$in" | jq -r '.tool_input.file_path // empty')
protected='\.claude/battery/(battery\.sh|guard\.sh|battery\.conf)|\.claude/settings\.json|(^|/)test\.sh'
if [ -n "$file" ] && echo "$file" | grep -Eq "$protected"; then
	echo "That file belongs to the test battery and is changed by the human only. If its rules block you, stop and say why." >&2
	exit 2
fi
# In commands the file name may stand alone ("> test.sh"), so no leading-slash anchor there.
protected_cmd='\.claude/battery/(battery\.sh|guard\.sh|battery\.conf)|\.claude/settings\.json|test\.sh([^A-Za-z0-9_.-]|$)'
if [ -n "$cmd" ]; then
	# Benchmarks with tests switched off (-run '^$') verify nothing, so they may run directly.
	bench_only=false
	echo "$cmd" | grep -Eq -- '-bench[= ]' && echo "$cmd" | grep -Eq -- "-run[= ]+['\"]?\^\\\$['\"]?([[:space:]]|$)" &&
		[ "$(echo "$cmd" | grep -Eo -- '-run[= ]' | wc -l)" -eq 1 ] && [ "$(echo "$cmd" | grep -Eo 'go[[:space:]]+(test|vet)' | wc -l)" -eq 1 ] && bench_only=true
	if [ $bench_only = false ] && echo "$cmd" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+(test|vet)([[:space:]]|$)'; then
		echo "Don't run go test/vet directly (benchmarks are fine as go test -run '^$' -bench X). Use ./test.sh [unit|lint|integration] [pkg|file_test.go] [-run X], or ./test.sh cover for changed lines no test executes. It reuses the result for the current files when the background battery already has one." >&2
		exit 2
	fi
	# Only when a protected file is the TARGET of a write: redirected into, or an argument of a command
	# that changes files. Running ./test.sh 2>&1 | tail, or cat-ing a log, stays allowed.
	if echo "$cmd" | grep -Eq "[0-9]?>>?[[:space:]]*[^[:space:];&|]*($protected_cmd)" ||
	   echo "$cmd" | grep -Eq "(sed[[:space:]]+-i|tee|mv|cp|rm|chmod|ln|truncate|perl[[:space:]]+-[a-z]*i|python3?)[^;&|]*($protected_cmd)"; then
		echo "That command would change the test battery's own files, which only the human changes. If its rules block you, stop and say why." >&2
		exit 2
	fi
fi
exit 0

#!/usr/bin/env bash
# Install cotest into a Go repo.
#   install.sh <project-dir>
# Idempotent: re-running updates the scripts and hooks, keeps an existing battery.conf and CLAUDE.md block.
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
DIR="$(cd "${1:?usage: install.sh <project-dir>}" && pwd)"
[ -f "$DIR/go.mod" ] || { echo "no go.mod in $DIR (cotest is Go-only)" >&2; exit 1; }
[ -d "$DIR/.git" ] || { echo "$DIR is not a git repo (the cache keys on git trees)" >&2; exit 1; }
for t in jq perl git go; do command -v $t >/dev/null || { echo "missing $t" >&2; exit 1; }; done

# 1. scripts
mkdir -p "$DIR/.claude/battery"
cp "$KIT/battery.sh" "$KIT/guard.sh" "$DIR/.claude/battery/"
chmod +x "$DIR/.claude/battery/battery.sh" "$DIR/.claude/battery/guard.sh"
echo "write   .claude/battery/battery.sh, guard.sh"
if [ -f "$DIR/.claude/battery/battery.conf" ]; then echo "keep    .claude/battery/battery.conf"
else cp "$KIT/battery.conf.template" "$DIR/.claude/battery/battery.conf"; echo "create  .claude/battery/battery.conf"; fi
if [ -e "$DIR/test.sh" ] && ! grep -q 'battery.sh" test' "$DIR/test.sh"; then
	echo "test.sh exists and is not ours; leaving it, entrypoint is .claude/battery/battery.sh test" >&2
else cp "$KIT/test.sh" "$DIR/test.sh"; chmod +x "$DIR/test.sh"; echo "write   test.sh"; fi

# 2. hooks, merged into .claude/settings.json (other hooks are kept)
python3 - "$DIR/.claude/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path)) if os.path.exists(path) else {}
hooks = s.setdefault("hooks", {})
want = {
    "PostToolUse": ("Write|Edit|MultiEdit|Bash", '"$CLAUDE_PROJECT_DIR"/.claude/battery/battery.sh kick', 5),
    "PreToolUse":  ("Bash|Write|Edit|MultiEdit", '"$CLAUDE_PROJECT_DIR"/.claude/battery/guard.sh', 5),
    "Stop":        (None, '"$CLAUDE_PROJECT_DIR"/.claude/battery/battery.sh stop', 300),
}
for event, (matcher, cmd, timeout) in want.items():
    groups = hooks.setdefault(event, [])
    groups[:] = [g for g in groups if not any(".claude/battery/" in h.get("command", "") for h in g.get("hooks", []))]
    g = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
    if matcher: g = {"matcher": matcher, **g}
    groups.append(g)
json.dump(s, open(path, "w"), indent=2)
open(path, "a").write("\n")
print("merge   .claude/settings.json")
PY

# 3. results stay out of git
for line in ".claude/battery/status/" ".claude/battery/battery.log"; do
	grep -qxF "$line" "$DIR/.gitignore" 2>/dev/null || { echo "$line" >> "$DIR/.gitignore"; echo "append  .gitignore: $line"; }
done

# 4. CLAUDE.md rule (replace our block if present, so wording updates reach old installs)
if grep -Eq '<!-- (test-battery|cotest):start -->' "$DIR/CLAUDE.md" 2>/dev/null; then
	python3 - "$DIR/CLAUDE.md" "$KIT/CLAUDE.snippet.md" <<'PY'
import re, sys
p, snip = sys.argv[1], open(sys.argv[2]).read().strip()
s = open(p).read()
s = re.sub(r"<!-- (?:test-battery|cotest):start -->.*?<!-- (?:test-battery|cotest):end -->", lambda m: snip, s, flags=re.S)
open(p, "w").write(s)
PY
	echo "update  CLAUDE.md (test-battery block)"
else
	{ [ -f "$DIR/CLAUDE.md" ] && echo; cat "$KIT/CLAUDE.snippet.md"; } >> "$DIR/CLAUDE.md"
	echo "append  CLAUDE.md"
fi

# 5. self-check: the battery must hash, run and report on this repo
echo "check   ./test.sh unit (first run, fills the cache)"
if (cd "$DIR" && CLAUDE_PROJECT_DIR="$DIR" ./test.sh unit > /tmp/cotest-install.$$ 2>&1); then
	grep -E '^(PASS|FAIL)' /tmp/cotest-install.$$ | sed 's/^/        /'
else
	sed 's/^/        /' /tmp/cotest-install.$$; echo "unit tests are red in $DIR; cotest works, the code does not" >&2
fi
rm -f /tmp/cotest-install.$$
echo '{"tool_input":{"command":"go test ./..."}}' | "$DIR/.claude/battery/guard.sh" 2>/dev/null && { echo "guard did not block go test" >&2; exit 1; } || echo "check   guard blocks direct go test"
echo "done. Restart Claude sessions in $DIR so they load the hooks."

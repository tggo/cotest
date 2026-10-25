#!/bin/bash
# Background continuous testing (cotest) with a per-package cache.
#   battery.sh kick                 PostToolUse: bump generation, spawn a worker, return at once
#   battery.sh worker GEN           debounce, find packages whose inputs changed, test only those
#   battery.sh test [LEVEL] [PATH…] [-run RE]   the one way to run tests (see test.sh)
#   battery.sh stop                 Stop hook: every package at every level must be green for the current files
#
# A result is cached per (level, package, -run filter) under the hash of the package's own files plus
# every in-module package it depends on (with that level's build tags), plus go.mod/go.sum. Editing one
# domain therefore leaves the cache of an unrelated domain valid. Files in non-package subdirectories
# (testdata/, embedded assets) count for the package that encloses them. Paths in BATTERY_GLOBAL
# (space-separated files or dirs, e.g. "migrations docker-compose.yml") count for every package.
#
# Results are kept per hash in status/<level>/<key>/<hash>.{st,log}, so reverting an edit finds the old
# result instead of re-running. status/<level>/<key>.log is a copy of the newest log for humans.
# A .st file is one line: "hash state ok by secs".
# The hot path (hashing, checking, waiting) runs one `go list` and one `git ls-tree` per level and
# otherwise only bash builtins.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
ROOT=$(cd -P "$ROOT" && pwd) # ~/code is a symlink; go list and git must see the same paths
B="$ROOT/.claude/battery"
S="$B/status"
mkdir -p "$S"
# Per-project settings (BATTERY_GLOBAL, BATTERY_LEVELS, …) live next to this script.
[ -f "$B/battery.conf" ] && . "$B/battery.conf"
DEBOUNCE="${BATTERY_DEBOUNCE:-2}"
MAX_ATTEMPTS="${BATTERY_MAX_ATTEMPTS:-3}"
# The integration level only exists once some test file carries the tag; until then it would just repeat unit.
if [ -n "${BATTERY_LEVELS:-}" ]; then LEVELS=$BATTERY_LEVELS
elif git -C "$ROOT" grep --untracked -qlE '^//go:build .*integration' -- '*_test.go' 2>/dev/null; then LEVELS="unit lint integration"
else LEVELS="unit lint"; fi
MOD=$(awk '/^module /{print $2; exit}' "$ROOT/go.mod")

log() { echo "$(perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%03d", strftime("%H:%M:%S",localtime $t), ($t-int $t)*1000') [$1] ${*:2}" >> "$B/battery.log"; }

tags_for() { [ "$1" = integration ] && echo "-tags integration"; }
rel() { local r=${1#$MOD}; r=${r#/}; echo "${r:-.}"; } # import path -> path relative to module
key() { local r; r=$(rel "$1"); r=${r//\//_}; [ -n "${2:-}" ] && r+="@${2//[^A-Za-z0-9_]/_}"; echo "$r"; }
worker_alive() { [ -f "$S/worker.pid" ] && kill -0 "$(cat "$S/worker.pid")" 2>/dev/null; }

# Hash of the working tree including untracked files, without touching the real index.
tree_hash() {
	local idx; idx=$(mktemp)
	cp "$ROOT/.git/index" "$idx" 2>/dev/null
	GIT_INDEX_FILE="$idx" git -C "$ROOT" add -A -- . ':!.claude/battery' >/dev/null 2>&1
	GIT_INDEX_FILE="$idx" git -C "$ROOT" write-tree
	rm -f "$idx"
}

# Fill H_<level>_<pkg> and PKGS_<level> for every package in the module, for the tree in $TREE.
# One `go list -test -deps` gives each package's test closure; one `git ls-tree -r` gives file blobs.
load_hashes() { # level…
	local lvl q out lst
	lst=$(mktemp); git -C "$ROOT" ls-tree -r "$TREE" > "$lst"
	for lvl in "$@"; do
		q=$lvl; [ "$lvl" = lint ] && q=unit # vet sees the same files as unit tests
		out=$(cd "$ROOT" && go list $(tags_for "$q") -test -deps \
			-f '{{if not .Standard}}{{.ImportPath}}	{{.Dir}}	{{.ForTest}}	{{join .Deps " "}}{{end}}' ./... 2>/dev/null |
			awk -F'\t' -v root="$ROOT" -v lst="$lst" -v global="go.mod go.sum ${BATTERY_GLOBAL:-}" '
				BEGIN { ng=split(global, G, " ")
				        while((getline line < lst) > 0){ split(line, a, "\t"); split(a[1], m, " ")
				          nb++; BP[nb]=a[2]; BH[nb]=m[3]
				          for(g=1;g<=ng;g++) if(a[2]==G[g] || index(a[2], G[g] "/")==1) mod=mod m[3] " " a[2] ";" } }
				NF>=2 { ip=$1; sub(/ \[.*/, "", ip); if(ip ~ /\.test$/) next
				        owner=($3!="")?$3:ip; dir[ip]=$2; own[NR]=owner; self[NR]=ip; deps[NR]=$4; if($3=="") top[ip]=1 }
				END { for(r in own){ o=own[r]; if(!top[o]) continue
				        k=split(deps[r], D, " "); D[++k]=self[r]
				        for(j=1;j<=k;j++){ dp=D[j]; sub(/ \[.*/, "", dp); dd=dir[dp]; if(index(dd, root)!=1) continue
				          rd=substr(dd, length(root)+2); if(rd=="") rd="."; print o "\t" rd } }
				      # Every file belongs to the nearest enclosing package dir, so testdata/, embedded
				      # assets and other non-package subdirectories invalidate the package that owns them.
				      for(ip in dir){ dd=dir[ip]; if(index(dd, root)!=1) continue; rd=substr(dd, length(root)+2); if(rd=="") rd="."; isp[rd]=1 }
				      for(i=1;i<=nb;i++){ d=BP[i]
				        do { if(d ~ /\//) sub("/[^/]*$", "", d); else d="." } while(!(d in isp) && d!=".")
				        if(d in isp) sig[d]=sig[d] BH[i] " " BP[i] "\n" }
				      for(d in sig) print "\tSIG\t" d "\t" sig[d]; print "\tMOD\t" mod }' |
			perl -e '
				my (%dirs, %sig, $mod);
				local $/ = undef; my $in = <STDIN>;
				while ($in =~ /^\tSIG\t([^\t]*)\t(.*?)(?=^\t|\z)/msg) { $sig{$1} = $2 }
				$mod = $1 if $in =~ /^\tMOD\t(.*)$/m;
				for (split /\n/, $in) { next if /^\t/ || !/\t/; my ($o, $d) = split /\t/; $dirs{$o}{$d} = 1 }
				use Digest::SHA qw(sha1_hex);
				for my $o (sort keys %dirs) {
					print "$o ", sha1_hex(join("|", "'"$lvl"'", $mod, map { "$_:" . ($sig{$_} // "") } sort keys %{$dirs{$o}})), "\n";
				}')
		eval "PKGS_$lvl=\"\""
		while read -r ip h; do
			[ -z "$ip" ] && continue
			eval "H_${lvl}_${ip//[^A-Za-z0-9]/_}=$h"
			eval "PKGS_$lvl+=\" $ip\""
		done <<< "$out"
	done
	rm -f "$lst"
}
res() { echo "$S/$1/$(key "$2" "$3")/$(scope_hash "$1" "$2")"; } # result path prefix for the current hash
scope_hash() { local v="H_${1}_${2//[^A-Za-z0-9]/_}"; echo "${!v:-none}"; }
pkgs_of() { local v="PKGS_$1"; echo "${!v}"; }

state_of() { # level pkg run -> "fresh" | "running" | "stale"
	local f; f=$(res "$1" "$2" "$3").st; local h st rest
	[ -f "$f" ] || { echo stale; return; }
	read -r h st rest < "$f"
	[ "$h" = "$(scope_hash "$1" "$2")" ] || { echo stale; return; }
	# A test result without its coverage slice (from an older battery) cannot answer the coverage check.
	if [ "$st" = done ] && [ -z "$3" ] && [ "$1" != lint ] && [ ! -f "${f%.st}.cover" ]; then echo stale; return; fi
	[ "$st" = done ] && echo fresh || echo running
}

# Per-file report for one package from its `go test -json` events (only runs after a real test run).
render() { # level importpath events-file
	local dir="$ROOT/$(rel "$2")"
	if [ "$1" = lint ]; then
		[ -s "$3" ] && sed "s#^$ROOT/##; s#^#    #" "$3" || echo "    go vet: no issues"
		return
	fi
	if grep -q '\[no test files\]' "$3" 2>/dev/null; then echo "    no test files"; return; fi
	{
		grep -Ho '^func Test[A-Za-z0-9_]*' "$dir"/*_test.go 2>/dev/null | sed 's#^.*/##; s#:func #\t#; s#^#MAP\t#'
		jq -r 'select(.Test!=null and (.Test|contains("/")|not) and (.Action=="pass" or .Action=="fail" or .Action=="skip"))
			| "RES\t\(.Test)\t\(.Action)\t\(.Elapsed)"' "$3"
	} | awk -F'\t' '
		$1=="MAP" { file[$3]=$2; next }
		$1=="RES" { f=($2 in file)?file[$2]:"?"; if(!(f in n)){order[++k]=f}; n[f]++; t[f]+=$4
		            if($3=="fail"){bad[f]++; failed[f]=failed[f]" "$2} }
		END { for(i=1;i<=k;i++){f=order[i]
		        printf "    %-26s %s  %d test%s  %.2fs%s\n", f, (bad[f]?"FAIL":"PASS"), n[f], (n[f]==1?"":"s"), t[f], (bad[f]?"  ->"failed[f]:"") } }'
	# Output of failing tests, or of the package itself when it failed without a failing test (build error).
	jq -r 'select(.Action=="output" and .Test!=null) | "\(.Test)\t\(.Output)"' "$3" > "$3.out"
	for t in $(jq -r 'select(.Action=="fail" and .Test!=null and (.Test|contains("/")|not)) | .Test' "$3"); do
		echo "    --- $t"
		awk -F'\t' -v t="$t" '$1==t || index($1, t"/")==1 {print "      " $2}' "$3.out" | sed '/^      $/d' | tail -20
	done
	if jq -e 'select(.Action=="fail" and .Test==null)' "$3" >/dev/null && ! jq -e 'select(.Action=="fail" and .Test!=null)' "$3" >/dev/null; then
		jq -r 'select(.Action=="output" and .Test==null) | .Output' "$3" | sed '/^$/d; s/^/      /' | tail -20
	fi
	rm -f "$3.out"
}

# What "changed" is measured against. The first edit after a green Stop records HEAD as the session
# base, so lines the agent commits mid-session are still checked. BATTERY_COVER_BASE overrides it for an audit.
cover_base() {
	local b; b=${BATTERY_COVER_BASE:-$(cat "$S/session.base" 2>/dev/null)}
	if [ -n "$b" ] && git -C "$ROOT" merge-base --is-ancestor "$b" HEAD 2>/dev/null; then echo "$b"; else echo HEAD; fi
}

# A worker whose tree is no longer the newest was cancelled: what its killed processes report is noise.
superseded() { [ "$1" = worker ] && [ "$(cat "$S/worker.tree" 2>/dev/null)" != "$TREE" ]; }

# Packages that own a changed (vs the session base) or untracked .go file, at one level.
changed_pkgs() { # level
	local d p all; all=" $(pkgs_of "$1") "
	for d in $( { git -C "$ROOT" diff --name-only "$(cover_base)" -- '*.go'; git -C "$ROOT" ls-files -o --exclude-standard -- '*.go'; } | xargs -n1 dirname 2>/dev/null | sort -u); do
		p="$MOD/$d"; [ "$d" = . ] && p=$MOD
		case $all in *" $p "*) echo "$p" ;; esac
	done
}

# Write the result of one package from its events file; called as each package finishes.
finalize() { # level run by pkg ok t0
	local lvl=$1 run=$2 by=$3 p=$4 ok=$5 t0=$6 r h ev
	r=$(res "$lvl" "$p" "$run"); h=$(scope_hash "$lvl" "$p"); ev="$r.events"
	{ echo "# level=$lvl package=$(rel "$p") run=${run:-all} hash=$h"
	  echo "# finished=$(date '+%F %T') by=$by ok=$ok"
	  render "$lvl" "$p" "$ev"; } > "$r.log"
	local prev flaky=false failed=""
	[ "$lvl" != lint ] && failed=$(jq -r 'select(.Action=="fail" and .Test!=null and (.Test|contains("/")|not)) | .Test' "$ev" | paste -sd, -)
	# A failed test that passes on an immediate rerun of the same files is flaky, not broken by the change.
	# The result stays red: the agent is told which tests are flaky instead of chasing its own diff.
	if [ "$ok" = false ] && [ -n "$failed" ] &&
	   (cd "$ROOT" && BATTERY_RUN_ID="${lvl}_retry_$$" go test -count=1 $(tags_for "$lvl") ${BATTERY_TEST_FLAGS:-} -run "^(${failed//,/|})\$" "$p" > /dev/null 2>&1); then
		flaky=true; echo "    FLAKY: ${failed//,/, } failed, then passed on an immediate rerun of the same files" >> "$r.log"
	fi
	# Same files, different outcome than an earlier run: also flaky.
	prev=$(awk -v l="$lvl" -v p="$(rel "$p")" -v h="$h" -v r="${run:-}" 'index($0, "\"level\":\"" l "\"") && index($0, "\"pkg\":\"" p "\"") && index($0, "\"hash\":\"" h "\"") && index($0, "\"run\":\"" r "\"") {last=$0} END {print last}' "$S/runs.jsonl" 2>/dev/null)
	if [ "$flaky" = false ] && [ -n "$prev" ] && ! echo "$prev" | grep -q "\"ok\":$ok"; then
		flaky=true; echo "    FLAKY: same files passed/failed differently on an earlier run" >> "$r.log"
	fi
	cp "$r.log" "$S/$lvl/$(key "$p" "$run").log"
	# The package's own duration (go reports it); wall time since the batch started is a fallback.
	local secs; secs=$( [ "$lvl" != lint ] && jq -rs '[.[]|select(.Test==null and .Elapsed!=null)]|last|.Elapsed // empty|floor' "$ev" 2>/dev/null)
	[ -z "$secs" ] && secs=$(( $(date +%s) - t0 ))
	jq -cn --arg at "$(date '+%F %T')" --arg level "$lvl" --arg pkg "$(rel "$p")" --arg run "${run:-}" --arg hash "$h" \
		--argjson ok "$ok" --arg by "$by" --argjson secs "$secs" --arg failed "$failed" --argjson flaky $flaky \
		'{at:$at,level:$level,pkg:$pkg,run:$run,hash:$hash,ok:$ok,by:$by,secs:$secs,failed:($failed|split(",")|map(select(.!=""))),flaky:$flaky}' >> "$S/runs.jsonl"
	echo "$h done $ok $by $secs" > "$r.st.tmp" && mv "$r.st.tmp" "$r.st"
	# Keep the newest results per package; older trees are unlikely to come back.
	ls -t "$(dirname "$r")"/*.st 2>/dev/null | tail -n +"$(( ${BATTERY_KEEP:-20} + 1 ))" | sed 's/\.st$//' |
		while read -r old; do rm -f "$old".st "$old".log "$old".events "$old".cover; done
	log "$lvl" "$(rel "$p")${run:+ -run $run} ok=$([ "$ok" = true ] && echo yes || echo NO) by=$by ${secs}s"
}

# Run one level for a set of packages. Tests go through ONE `go test -json` (go parallelises packages
# itself and shares the build), and a splitter finalizes each package the moment its last event arrives,
# so a fast package does not wait for a slow one. Coverage is collected so Stop can check changed lines.
run_batch() { # level run by pkg…
	local lvl=$1 run=$2 by=$3 p r t0 tmp; shift 3
	[ $# = 0 ] && return
	t0=$(date +%s); tmp=$(mktemp -d)
	for p in "$@"; do r=$(res "$lvl" "$p" "$run"); mkdir -p "$(dirname "$r")"; echo "$(scope_hash "$lvl" "$p") running - $by 0" > "$r.st"; done
	if [ "$lvl" = lint ]; then
		# vet per package, capped at BATTERY_JOBS at a time
		local n=0
		for p in "$@"; do
			( r=$(res "$lvl" "$p" "$run")
			  (cd "$ROOT" && go vet "$p" > "$r.events" 2>&1) && ok=true || ok=false
			  superseded "$by" || finalize "$lvl" "$run" "$by" "$p" "$ok" "$t0" ) &
			n=$((n + 1)); [ $((n % ${BATTERY_JOBS:-8})) = 0 ] && wait
		done
		wait
	else
		# Integration tests that share a database can namespace it by BATTERY_RUN_ID (unique per go test run).
		(cd "$ROOT" && BATTERY_RUN_ID="${lvl}_$(date +%s)_$$" go test -json $(tags_for "$lvl") ${BATTERY_TEST_FLAGS:-} ${run:+-run "$run"} \
			$([ "$lvl" = integration ] && echo -count=1) -coverprofile="$tmp/cover" "$@" 2> "$tmp/stderr") |
		perl -MJSON::PP -e '
			my ($dir) = @ARGV; $| = 1; my $js = JSON::PP->new->canonical;
			while (my $l = <STDIN>) {
				my $e = eval { $js->decode($l) } or next;
				if (($e->{Action} // "") eq "build-output") { # compile errors arrive keyed by ImportPath
					(my $ip = $e->{ImportPath} // "") =~ s/ \[.*//;
					$e = { Package => $ip, Action => "output", Output => $e->{Output} };
				}
				my $p = $e->{Package} or next;
				(my $f = $p) =~ s/[^A-Za-z0-9]/_/g;
				open my $fh, ">>", "$dir/$f" or die; print $fh $js->encode($e), "\n"; close $fh;
				if (!defined $e->{Test} && $e->{Action} =~ /^(pass|fail|skip)$/) {
					print join("\t", "DONE", $p, $e->{Action}, "$dir/$f"), "\n";
				}
			}' "$tmp" |
		while IFS=$'\t' read -r _ p action f; do
			superseded "$by" && break
			r=$(res "$lvl" "$p" "$run"); [ -f "$r.st" ] || continue
			mv "$f" "$r.events"
			finalize "$lvl" "$run" "$by" "$p" "$([ "$action" = fail ] && echo false || echo true)" "$t0"
		done
		superseded "$by" && { rm -rf "$tmp"; return; }
		for p in "$@"; do
			r=$(res "$lvl" "$p" "$run")
			# A package that never reported (setup failure) fails with go's stderr.
			if read -r _ st _ < "$r.st" && [ "$st" = running ]; then
				jq -cn --arg p "$p" --arg o "$(cat "$tmp/stderr")" '{Package:$p,Action:"output",Output:$o},{Package:$p,Action:"fail"}' > "$r.events"
				finalize "$lvl" "$run" "$by" "$p" false "$t0"
			fi
			# Per-package slice of the merged profile: blocks of files that sit directly in this package.
			[ -f "$tmp/cover" ] && awk -v p="$p/" 'NR==1 {print; next} index($0, p)==1 && substr($0, length(p)+1) !~ /\// {print}' "$tmp/cover" > "$r.cover"
		done
	fi
	rm -rf "$tmp"
}

# Changed lines (working tree vs the session base, see cover_base; non-test .go files, untracked included) that sit inside a
# statement block no test executed, at any level. Prints "file: a-b, c" per file; empty = all covered.
uncovered_changes() {
	local changes lv p f d profiles=""
	changes=$( { git -C "$ROOT" diff -U0 "$(cover_base)" -- '*.go' ':(exclude)*_test.go' |
			awk '/^\+\+\+ b\// {f=substr($0, 7)} /^@@/ {split($3, a, ","); s=substr(a[1], 2); n=(a[2]=="")?1:a[2]; if(n>0) print f "\t" s "\t" s+n-1}'
		git -C "$ROOT" ls-files -o --exclude-standard -- '*.go' | grep -v '_test\.go$' |
			while read -r f; do echo "$f	1	$(wc -l < "$ROOT/$f")"; done; } |
		while IFS=$'\t' read -r f a b; do
			head -3 "$ROOT/$f" 2>/dev/null | grep -q 'Code generated .* DO NOT EDIT' && continue
			for g in ${BATTERY_COVER_IGNORE:-}; do case $f in ($g) continue 2 ;; esac; done
			echo "$f	$a	$b"
		done)
	[ -z "$changes" ] && return
	for d in $(echo "$changes" | cut -f1 | xargs -n1 dirname | sort -u); do
		p="$MOD/$d"; [ "$d" = . ] && p=$MOD
		for lv in unit integration; do case " $LEVELS " in *" $lv "*) [ -f "$(res "$lv" "$p" "").cover" ] && profiles+=" $(res "$lv" "$p" "").cover" ;; esac; done
	done
	{ echo "$changes" | sed 's/^/CHG\t/'; [ -n "$profiles" ] && cat $profiles | grep -v '^mode:' | sed "s#^$MOD/##; s/^/COV\t/"; } |
	awk -F'\t' '
		$1=="CHG" { n++; cf[n]=$2; ca[n]=$3; cb[n]=$4; next }
		$1=="COV" { split($2, x, ":"); file=x[1]; split(x[2], y, ","); split(y[1], s, "."); split(y[2], e, " "); split(e[1], ee, ".")
		            cnt=e[3]; for(l=s[1]; l<=ee[1]; l++){ k=file SUBSEP l; if(cnt>0) hit[k]=1; else blk[k]=1 } }
		END { for(i=1;i<=n;i++) for(l=ca[i]; l<=cb[i]; l++){ k=cf[i] SUBSEP l
		        if((k in blk) && !(k in hit) && !(k in seen)){ seen[k]=1; lines[cf[i]]=lines[cf[i]] " " l } }
		      for(f in lines){ m=split(substr(lines[f], 2), L, " "); out=""; a=L[1]; b=L[1]
		        for(j=2;j<=m+1;j++){ if(j<=m && L[j]==b+1){ b=L[j]; continue }
		          out=out (out==""?"":", ") (a==b ? a : a "-" b); a=L[j]; b=L[j] }
		        print f ": " out } }' | sort
}

# Make sure every package has a result for the current files: reuse, wait for the worker, or run now.
ensure() { # level run by pkg…
	local lvl=$1 run=$2 by=$3; shift 3
	local p todo st waiting i
	for i in $(seq 1 600); do
		todo=""; waiting=0
		for p in "$@"; do
			st=$(state_of "$lvl" "$p" "$run")
			case $st in
			fresh) ;;
			running) if [ -z "$run" ] && worker_alive; then waiting=1; else todo+=" $p"; fi ;;
			stale) if [ -z "$run" ] && { [ -f "$S/pending" ] || worker_alive; }; then waiting=1; else todo+=" $p"; fi ;;
			esac
		done
		[ -n "$todo" ] && { log "$by" "$lvl: running now: $(echo $todo | wc -w | tr -d ' ') pkg(s): $(echo $todo | tr ' ' '\n' | head -3 | while read -r x; do rel "$x"; done | paste -sd' ' -)"; run_batch "$lvl" "$run" "$by" $todo; continue; }
		[ $waiting = 0 ] && return
		sleep 0.3
	done
}

kill_tree() { # macOS has no setsid(1); walk the tree so `go test` and its test binary die too
	local c
	for c in $(pgrep -P "$1"); do kill_tree "$c"; done
	kill -TERM "$1" 2>/dev/null
}

case ${1:-} in
kick)
	cat > /dev/null
	gen=$(( $(cat "$S/gen" 2>/dev/null || echo 0) + 1 ))
	echo $gen > "$S/gen"
	touch "$S/pending"
	[ -f "$S/session.base" ] || git -C "$ROOT" rev-parse -q --verify HEAD > "$S/session.base" 2>/dev/null || rm -f "$S/session.base"
	# The hook runner waits for stdout/stderr to close, so detach every fd.
	nohup "$0" worker $gen < /dev/null > /dev/null 2>&1 &
	exit 0
	;;
worker)
	my=$2
	sleep "$DEBOUNCE"
	[ "$(cat "$S/gen")" = "$my" ] || exit 0 # a newer edit owns the run
	TREE=$(tree_hash)
	if worker_alive && [ "$(cat "$S/worker.tree" 2>/dev/null)" = "$TREE" ]; then
		rm -f "$S/pending"; log worker "gen=$my tree=${TREE:0:8} already running, skip"; exit 0
	fi
	load_hashes $LEVELS
	stale=""
	for l in $LEVELS; do
		for p in $(pkgs_of "$l"); do [ "$(state_of "$l" "$p" "")" = fresh ] || stale+=" $l:$(rel "$p")"; done
	done
	if [ -z "$stale" ]; then rm -f "$S/pending"; log worker "gen=$my tree=${TREE:0:8} nothing changed, skip"; exit 0; fi
	# Claim the tree first, so the run being cancelled sees it is superseded and records nothing.
	old=$(cat "$S/worker.pid" 2>/dev/null); echo "$TREE" > "$S/worker.tree"
	if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then log worker "gen=$my cancels stale pid $old"; kill_tree "$old"; fi
	echo $$ > "$S/worker.pid"; rm -f "$S/pending"
	log worker "gen=$my tree=${TREE:0:8} stale:$stale"
	for l in $LEVELS; do
		pk=""; for p in $(pkgs_of "$l"); do [ "$(state_of "$l" "$p" "")" = fresh ] || pk+=" $p"; done
		# Packages whose own files changed go first: Stop waits for them, the dependents can trail behind.
		ch=" $(changed_pkgs "$l" | tr '\n' ' ') "; first=""; rest=""
		for p in $pk; do case $ch in *" $p "*) first+=" $p" ;; *) rest+=" $p" ;; esac; done
		[ -n "$pk" ] && { run_batch "$l" "" worker $first; superseded worker || run_batch "$l" "" worker $rest; } &
	done
	wait
	rm -f "$S/worker.pid"
	;;
test)
	shift
	TREE=$(tree_hash)
	if [ "${1:-}" = cover ]; then
		# Changed lines that no test executes, after making sure the packages that own them are tested.
		load_hashes $LEVELS
		for l in $LEVELS; do
			[ "$l" = lint ] && continue
			pk=$(changed_pkgs "$l"); [ -n "$pk" ] && ensure "$l" "" test $pk
		done
		unc=$(uncovered_changes)
		if [ -z "$unc" ]; then echo "every changed line is executed by a test"; exit 0; fi
		echo "changed lines not executed by any test:"; echo "$unc" | sed 's/^/  /'; exit 1
	fi
	levels=""; paths=""; run=""
	while [ $# -gt 0 ]; do
		case $1 in
		unit|lint|integration) levels+=" $1" ;;
		all) levels=" $LEVELS" ;;
		-run) run=$2; shift ;;
		*_test.go)
			# One test file: its package, its level (from the build tag), only the tests it declares.
			f=${1#./}; paths+=" ./$(dirname "$f")"
			[ -z "$levels" ] && { grep -q '^//go:build integration' "$ROOT/$f" && levels=" integration" || levels=" unit"; }
			names=$(grep -o '^func Test[A-Za-z0-9_]*' "$ROOT/$f" | sed 's/^func //' | paste -sd'|' -)
			run="^(${names})\$" ;;
		*) p=${1#./}; paths+=" ./${p%/}" ;;
		esac
		shift
	done
	[ -z "$levels" ] && levels=" $LEVELS"
	load_hashes $levels
	rc=0
	for l in $levels; do
		if [ -z "$paths" ]; then pkgs=$(pkgs_of "$l")
		else pkgs=$(cd "$ROOT" && go list $(tags_for "$l") $paths 2>&1) || { echo "$pkgs"; exit 1; }
		fi
		before=""; for p in $pkgs; do [ "$(state_of "$l" "$p" "$run")" = fresh ] && before+=" $p "; done
		ensure "$l" "$run" test $pkgs
		echo "== $l${run:+  -run $run}"
		for p in $pkgs; do
			f=$(res "$l" "$p" "$run")
			read -r h st ok by secs < "$f.st"
			case $before in *" $p "*) how=cached ;; *) [ "$by" = test ] && how=ran || how=waited ;; esac
			printf '%s %s  (%s, hash %s)  log: %s\n' "$([ "$ok" = true ] && echo PASS || echo FAIL)" "$(rel "$p")" \
				"$how" "${h:0:8}" ".claude/battery/status/$l/$(key "$p" "$run").log"
			tail -n +3 "$f.log"
			[ "$ok" = true ] || rc=1
		done
	done
	log test "levels=$levels paths=${paths:- ./...}${run:+ run=$run} rc=$rc"
	exit $rc
	;;
stop)
	in=$(cat)
	TREE=$(tree_hash)
	case $in in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) active=true ;; *) active=false ;; esac
	attempts=$(cat "$S/attempts" 2>/dev/null || echo 0)
	if [ "$active" = true ] && [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
		log stop "gave up after $attempts attempts"; echo 0 > "$S/attempts"
		echo "battery: still red after $attempts attempts, handing back to the human" >&2
		exit 0
	fi
	# Stopped again without changing anything: the agent is asking the human, not ignoring us.
	if [ "$active" = true ] && [ "$(cat "$S/red.tree" 2>/dev/null)" = "$TREE" ]; then
		log stop "tree=${TREE:0:8} unchanged since last RED, letting the agent hand back"; echo 0 > "$S/attempts"
		exit 0
	fi
	load_hashes $LEVELS
	fail=""
	for l in $LEVELS; do
		pkgs=$(pkgs_of "$l")
		# Integration tests of every dependent can take minutes after a change to a leaf package; by
		# default Stop waits only for the packages you changed (the worker still runs the rest).
		[ "$l" = integration ] && [ "${BATTERY_STOP_INTEGRATION:-changed}" = changed ] && pkgs=$(changed_pkgs integration)
		[ -z "$pkgs" ] && continue
		ensure "$l" "" stop $pkgs
		for p in $pkgs; do
			f=$(res "$l" "$p" "")
			read -r h st ok rest < "$f.st"
			[ "$ok" = true ] || fail+=$'\n'"== $l $(rel "$p") FAILED"$'\n'"$(tail -n +3 "$f.log")"
		done
	done
	if [ -n "$fail" ]; then
		echo $(( attempts + 1 )) > "$S/attempts"; echo "$TREE" > "$S/red.tree"
		log stop "tree=${TREE:0:8} RED (attempt $(( attempts + 1 )))"
		printf 'cotest: tests are red for the current files:%s\n\nRe-check one file with ./test.sh path/to/x_test.go\n' "$fail" >&2
		exit 2
	fi
	# Green is not enough: code you changed must be executed by some test.
	if [ "${BATTERY_COVER:-block}" != off ]; then
		unc=$(uncovered_changes)
		if [ -n "$unc" ]; then
			log stop "tree=${TREE:0:8} uncovered changes: $(echo "$unc" | tr '\n' ';')"
			if [ "${BATTERY_COVER:-block}" = block ]; then
				echo $(( attempts + 1 )) > "$S/attempts"; echo "$TREE" > "$S/red.tree"
				printf 'Tests are green, but these lines you changed are not executed by any test:\n%s\n\nAdd tests that run them (./test.sh cover shows what is still uncovered). If a line truly cannot be tested, stop and tell the human why; do not edit the battery settings.\n' "$(echo "$unc" | sed 's/^/  /')" >&2
				exit 2
			fi
		fi
	fi
	echo 0 > "$S/attempts"; rm -f "$S/session.base"
	log stop "tree=${TREE:0:8} green"
	exit 0
	;;
esac

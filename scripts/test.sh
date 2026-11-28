#!/bin/bash
# Builds and runs the tests, the suites split across several test processes: scripts/test.sh [-j workers] [--only Suite]...
set -uo pipefail
cd "$(dirname "$0")/.."

workers=6
only=()
while [ $# -gt 0 ]; do
  case "$1" in
    -j) workers="$2"; shift 2 ;;
    --only) only+=("$2"); shift 2 ;;
    *) echo "usage: scripts/test.sh [-j workers] [--only Suite]..." >&2; exit 2 ;;
  esac
done

dd=build/dd
logs=build/test-logs
rm -rf "$logs" && mkdir -p "$logs"
export TEST_RUNNER_ZIGZAG_TEST_VAULT=memory
# Suites run in a process of their own with every string pseudo-localized from launch (docs/i18n/README.md).
pseudo=(PseudoLocalizedLayoutTests)
xcb=(xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -destination 'platform=macOS' -derivedDataPath "$dd")

if ! "${xcb[@]}" build-for-testing -allowProvisioningUpdates > "$logs/build.log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$logs/build.log" | head -30
  echo "build failed, see $logs/build.log"; exit 1
fi

# One list of -only-testing suites per worker, the slowest suites (by the last run's times) shared out first.
if [ ${#only[@]} -gt 0 ]; then
  for suite in "${only[@]}"; do
    if printf '%s\n' "${pseudo[@]}" | grep -qx "$suite"; then shard=shard-pseudo; else shard=shard-0; fi
    printf -- '-only-testing:ZigzagTests/%s ' "$suite" >> "$logs/$shard"
  done
else
  "${xcb[@]}" test-without-building -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
    -test-enumeration-output-path "$logs/tests.json" > "$logs/enumerate.log" 2>&1 || { echo "couldn't list the tests"; exit 1; }
  python3 -I - "$logs/tests.json" build/test-times "$workers" "$logs" "${pseudo[@]}" <<'EOF'
import json, os, sys
tests, times_file, workers, logs = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
pseudo = sys.argv[5:]
# Suites this machine can't run (ZZ_SKIP_SUITES, e.g. keychain suites in the test VM) are left out.
skipped = os.environ.get("ZZ_SKIP_SUITES", "").split()
counts = {}
for value in json.load(open(tests))["values"]:
    for test in value["enabledTests"]:
        suite = test["identifier"].split("/")[1]
        if suite not in pseudo and suite not in skipped: counts[suite] = counts.get(suite, 0) + 1
times = {}
if os.path.exists(times_file):
    for line in open(times_file):
        seconds, suite = line.split()
        times[suite] = float(seconds)
shards = [[0.0, []] for _ in range(workers)]
for suite in sorted(counts, key=lambda s: -times.get(s, 0.1 * counts[s])):
    shard = min(shards, key=lambda s: s[0])
    shard[0] += times.get(suite, 0.1 * counts[suite])
    shard[1].append(suite)
# The first worker runs everything the others don't, so a test -only-testing can't name still runs.
others = [s for _, suites in shards[1:] for s in suites] + pseudo + skipped
open(f"{logs}/shard-0", "w").write(" ".join(f"-skip-testing:ZigzagTests/{s}" for s in others))
open(f"{logs}/shard-pseudo", "w").write(" ".join(f"-only-testing:ZigzagTests/{s}" for s in pseudo))
for i, (_, suites) in enumerate(shards[1:], 1):
    if suites: open(f"{logs}/shard-{i}", "w").write(" ".join(f"-only-testing:ZigzagTests/{s}" for s in suites))
EOF
fi

pids=()
# Ends what this run left running, however it ends: only processes whose executable is in this worktree's build, and
# the helpers launchd started for this run's test hosts (WebKit's too), which it doesn't always end with them.
products="$PWD/$dd/Build/Products/"
app="${products}Debug/Zigzag.app"
hosts="$logs/hosts"
# Processes whose executable path starts with $1.
running_from() {
  ps -axo pid=,comm= | awk -v p="$1" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if (index($0, p) == 1) print pid }'
}
in_build() { running_from "$products"; }
cleanup() {
  trap - EXIT INT TERM
  [ -n "${sampler:-}" ] && { kill "$sampler"; wait "$sampler"; } 2>/dev/null
  [ ${#pids[@]} -gt 0 ] && kill "${pids[@]}" 2>/dev/null
  left=$(in_build)
  if [ -n "$left" ]; then
    kill $left 2>/dev/null
    sleep 2
  fi
  # A host's helpers are the services in its launchd domain, which names the app that made it.
  for host in $(sort -u "$hosts" 2>/dev/null); do
    kill -0 "$host" 2>/dev/null && continue
    launchctl print "pid/$host" 2>/dev/null | awk -v app="$app" '
      $1 == "originator" { mine = ($3 == app) }
      /^\tservices = \{/ { on = 1; next }
      on && /^\t\}/ { on = 0 }
      on && $1 ~ /^[1-9][0-9]*$/ { services = services " " $1 }
      END { if (mine && services != "") print services }' | xargs kill -9 2>/dev/null
    # Suites its tests emptied, which the system wrote out again as it ended (DevDefaults.noteEmptiedSuite).
    list="$(getconf DARWIN_USER_TEMP_DIR)ZigzagTests-Suites-$host"
    [ -f "$list" ] || continue
    while read -r suite; do
      case "$suite" in ""|*/*|wang.zigao.zigzag*) continue ;; esac
      file="$HOME/Library/Preferences/$suite.plist"
      [ "$(plutil -convert json -o - "$file" 2>/dev/null)" = "{}" ] && rm -f "$file"
    done < "$list"
    rm -f "$list"
  done
  left=$(in_build)
  [ -n "$left" ] && kill -9 $left 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# The test hosts are gone by the end, so their IDs are noted while they run.
(while :; do running_from "$app/Contents/MacOS/Zigzag" >> "$hosts"; sleep 1; done) &
sampler=$!
for shard in $(ls "$logs" | grep -E '^shard-([0-9]+|pseudo)$' | sed "s|^|$logs/|"); do
  # The pseudo shard's test host starts with every string pseudo-localized.
  case "$shard" in *-pseudo) export TEST_RUNNER_ZIGZAG_PSEUDO_LOCALIZE=1 ;; *) unset TEST_RUNNER_ZIGZAG_PSEUDO_LOCALIZE ;; esac
  # shellcheck disable=SC2046
  "${xcb[@]}" test-without-building -parallel-testing-enabled NO -resultBundlePath "$shard.xcresult" $(cat "$shard") > "$shard.log" 2>&1 &
  pids+=($!)
done
unset TEST_RUNNER_ZIGZAG_PSEUDO_LOCALIZE
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done

# Suite times for the next run's split, and the summary.
[ ${#only[@]} -eq 0 ] && cat "$logs"/shard-*.log | grep -a -o -E '[✔✘] Suite [A-Za-z0-9_]+ (passed|failed) after [0-9.]+ seconds' \
  | awk '{ print $(NF-1), $3 }' > build/test-times
# Matched anywhere on a line: other output can run into the result without a line break.
cat "$logs"/shard-*.log | grep -a -o -E '[✔✘] Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)( after [0-9.]+ seconds)?.*' | awk -v failed=$status '
  { for (i = 1; i <= NF; i++) { if ($i ~ /^tests?$/) t += $(i-1); if ($i ~ /^suites?$/) s += $(i-1); if ($i == "after" && $(i+1) + 0 > secs) secs = $(i+1) + 0 }
    if ($0 ~ /failed after/) failed = 1 }
  END { printf "%d tests in %d suites %s, the slowest process %.1f s\n", t, s, failed ? "failed" : "passed", secs }'
grep -a -h "Test case '.*' failed on" "$logs"/shard-*.log | sed -E "s/Test case '([^']+)'.*/  failed: \1/" | sort -u
[ $status -eq 0 ] || echo "see $logs for the full logs"
exit $status

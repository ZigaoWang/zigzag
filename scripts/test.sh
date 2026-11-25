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
xcb=(xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -destination 'platform=macOS' -derivedDataPath "$dd")

if ! "${xcb[@]}" build-for-testing -allowProvisioningUpdates > "$logs/build.log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$logs/build.log" | head -30
  echo "build failed, see $logs/build.log"; exit 1
fi

# One list of -only-testing suites per worker, the slowest suites (by the last run's times) shared out first.
if [ ${#only[@]} -gt 0 ]; then
  printf '%s\n' "${only[@]}" | sed 's|^|-only-testing:ZigzagTests/|' | tr '\n' ' ' > "$logs/shard-0"
else
  "${xcb[@]}" test-without-building -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
    -test-enumeration-output-path "$logs/tests.json" > "$logs/enumerate.log" 2>&1 || { echo "couldn't list the tests"; exit 1; }
  python3 -I - "$logs/tests.json" build/test-times "$workers" "$logs" <<'EOF'
import json, os, sys
tests, times_file, workers, logs = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
counts = {}
for value in json.load(open(tests))["values"]:
    for test in value["enabledTests"]:
        suite = test["identifier"].split("/")[1]
        counts[suite] = counts.get(suite, 0) + 1
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
others = [s for _, suites in shards[1:] for s in suites]
open(f"{logs}/shard-0", "w").write(" ".join(f"-skip-testing:ZigzagTests/{s}" for s in others))
for i, (_, suites) in enumerate(shards[1:], 1):
    if suites: open(f"{logs}/shard-{i}", "w").write(" ".join(f"-only-testing:ZigzagTests/{s}" for s in suites))
EOF
fi

pids=()
for shard in $(ls "$logs" | grep -E '^shard-[0-9]+$' | sed "s|^|$logs/|"); do
  # shellcheck disable=SC2046
  "${xcb[@]}" test-without-building -parallel-testing-enabled NO -resultBundlePath "$shard.xcresult" $(cat "$shard") > "$shard.log" 2>&1 &
  pids+=($!)
done
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

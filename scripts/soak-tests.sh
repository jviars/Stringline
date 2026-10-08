#!/bin/bash
# Runs the end-to-end self-test several times in a row. If a run doesn't finish in time,
# it records a stack sample of the stuck app (stuck-N.txt) so the cause can be found, then moves on.
# Each run's assistant torture uses a new random seed (printed in its report).
# Usage: scripts/soak-tests.sh [runs]   (needs the Debug build from run-tests.sh)
#        STRINGLINE_TEST_ONLY=assistant scripts/soak-tests.sh 8   just the assistant checks, about a minute each
set -uo pipefail
cd "$(dirname "$0")/.."
RUNS="${1:-5}"
OUT="${TMPDIR:-/tmp}/stringline-tests"
APP="$OUT/build/Build/Products/Debug/Stringline.app/Contents/MacOS/Stringline"
failed=0
for ((i = 1; i <= RUNS; i++)); do
  rm -rf "$OUT/e2e"; mkdir -p "$OUT/e2e"
  STRINGLINE_TEST_OUT="$OUT/e2e" STRINGLINE_TEST_LOGO="$PWD/Stringline/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
    "$APP" -StringlineSelfTest > "$OUT/e2e/stdout.txt" 2>&1 &
  pid=$!; start=$SECONDS
  LIMIT=$([ "${STRINGLINE_TEST_ONLY:-}" = "assistant" ] && echo 300 || echo 1500)
  while kill -0 "$pid" 2>/dev/null && [ $((SECONDS - start)) -lt "$LIMIT" ]; do sleep 2; done
  if kill -0 "$pid" 2>/dev/null; then
    sample "$pid" 3 -file "$OUT/stuck-$i.txt" >/dev/null 2>&1
    kill -9 "$pid"; failed=$((failed + 1))
    echo "run $i: didn't finish in $((LIMIT / 60)) minutes (last screen $(ls "$OUT/e2e/screens" | tail -1)); stack sample in $OUT/stuck-$i.txt"
  else
    echo "run $i: $((SECONDS - start))s · $(tail -1 "$OUT/e2e/report.txt") · $(grep -o 'Torture seed [0-9]*' "$OUT/e2e/report.txt")"
    grep -q " 0 failed" "$OUT/e2e/report.txt" || { failed=$((failed + 1)); grep FAIL "$OUT/e2e/report.txt"; }
  fi
done
echo "$((RUNS - failed)) of $RUNS runs passed"
[ "$failed" -eq 0 ]

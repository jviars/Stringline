#!/bin/bash
# Force-quits the real app in the middle of saving, again and again, and checks after every crash that:
# every file is whole, nothing half-written is left, saves never went backwards, History is sound,
# and the app reopens normally (no problem screen, not blocked by its own lock).
# Usage: scripts/kill-test.sh [rounds]   (needs the Debug build and logic binary from run-tests.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
ROUNDS="${1:-100}"
OUT="${TMPDIR:-/tmp}/stringline-tests"
APP="$OUT/build/Build/Products/Debug/Stringline.app/Contents/MacOS/Stringline"
LOOP="$OUT/killtest"
rm -rf "$LOOP"; mkdir -p "$LOOP"
counter=0; bad=0; kills=0; reopened=0
for ((i = 1; i <= ROUNDS; i++)); do
  STRINGLINE_LOOP_FOLDER="$LOOP/PavingData" "$APP" -StringlineSaveLoop >/dev/null 2>&1 &
  pid=$!
  # Let it open and save for a random 1.5-4.5 seconds, then pull the plug.
  sleep "$(awk -v s=$RANDOM 'BEGIN { srand(s); printf "%.2f", 1.5 + rand() * 3 }')"
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; kills=$((kills + 1))
  status="$(cat "$LOOP/status.txt" 2>/dev/null)"
  result="$("$OUT/logic" --verify "$LOOP/PavingData" "$counter")"
  # An empty status just means it was killed before it finished opening; anything else must be "opened".
  if [[ "$result" == OK* ]] && [[ -z "$status" || "$status" == "opened" ]]; then
    counter="$(echo "$result" | awk '{print $3}')"
    [[ "$status" == "opened" ]] && reopened=$((reopened + 1))
  else
    bad=$((bad + 1)); echo "round $i: $result · app said: ${status:-nothing}"
  fi
  rm -f "$LOOP/status.txt"
done
echo "App kill test: $kills force-quits mid-save, reopened cleanly $reopened times, $bad problems, $counter saves recorded"
[ "$bad" -eq 0 ]

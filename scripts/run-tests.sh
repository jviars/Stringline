#!/bin/bash
# Runs the logic tests, then the end-to-end self-test in the real app.
# The self-test uses a throwaway data folder and never touches your real PavingData or app preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/stringline-tests"
rm -rf "$OUT/e2e" "$OUT/data"
mkdir -p "$OUT/data" "$OUT/e2e"

echo "== Logic and data-safety tests (includes killing a writer mid-save 300 times, about 40 seconds)"
swiftc -swift-version 5 -D STRINGLINE_TESTS -o "$OUT/logic" \
  Stringline/Models/*.swift \
  Stringline/Services/Estimator.swift Stringline/Services/WeatherJudge.swift Stringline/Services/Weather.swift \
  Stringline/Services/CalendarExport.swift Stringline/Services/ZohoImport.swift Stringline/Theme/Format.swift \
  Stringline/Store/JSONFile.swift Stringline/Store/SafeFile.swift Stringline/Store/DataFile.swift \
  Stringline/Store/Journal.swift Stringline/Store/FolderLock.swift Stringline/Store/SafetyModels.swift \
  Stringline/Assistant/JSONValue.swift Stringline/Assistant/OAuthCore.swift Stringline/Assistant/ResponsesStream.swift \
  Stringline/Assistant/ChangeOps.swift Stringline/Assistant/AssistantTools.swift Stringline/Assistant/AssistantPrompt.swift \
  Stringline/Assistant/LoopbackServer.swift Stringline/Assistant/TestSigningKey.swift \
  Stringline/Assistant/KnowledgeBase.swift Stringline/Assistant/ChatModels.swift Stringline/Assistant/ToolFuzzer.swift \
  Stringline/Assistant/MapFrame.swift Stringline/Assistant/MapTools.swift \
  Tests/main.swift Tests/SafetyTests.swift Tests/AssistantTests.swift Tests/AssistantTortureTests.swift Tests/AssistantMapTests.swift Tests/ZohoImportTests.swift
"$OUT/logic" "$OUT/data"

echo "== Building the app"
xcodebuild -project Stringline.xcodeproj -scheme Stringline -configuration Debug -derivedDataPath "$OUT/build" build -quiet

echo "== End-to-end self-test (the app opens and drives itself for a few minutes; keep it in front)"
STRINGLINE_TEST_OUT="$OUT/e2e" \
STRINGLINE_TEST_LOGO="$PWD/Stringline/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
  "$OUT/build/Build/Products/Debug/Stringline.app/Contents/MacOS/Stringline" -StringlineSelfTest
cat "$OUT/e2e/report.txt"
echo
echo "Screenshots and generated PDFs: $OUT/e2e/screens"
grep -q " 0 failed" "$OUT/e2e/report.txt"

echo
echo "== App kill test (force-quits the real app mid-save; run scripts/kill-test.sh 300 for a longer soak)"
scripts/kill-test.sh "${KILL_ROUNDS:-40}"

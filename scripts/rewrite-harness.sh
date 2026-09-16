#!/bin/sh
# Builds and runs the tier-two rewrite over a file of titles on the Mac's
# on-device model, using the app's own TitleRewriter and TitleCasing sources
# so a change to either is what gets exercised.
#
#   scripts/rewrite-harness.sh titles.txt "Breaking Points" [instructions.txt]
#
# The Mac's model is not the phone's: treat the output as a smoke test of the
# prompt and the validation, and check wording changes on hardware.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/yourtube-rewrite-harness"
mkdir -p "$OUT"
swiftc -O -parse-as-library -o "$OUT/rewrite-harness" \
  "$ROOT/scripts/rewrite-harness/main.swift" \
  "$ROOT/YourTube/Titles/TitleRewriter.swift" \
  "$ROOT/YourTube/Titles/TitleCasing.swift" 2>&1 | grep -v ' warning: ' || true
exec "$OUT/rewrite-harness" "$@"

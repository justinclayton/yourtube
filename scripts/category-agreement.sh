#!/bin/sh
# Compares YouTube's own per-video category against the on-device classifier's
# answer, over an export from Settings -> Categories -> "Export classifier
# evidence".
#
#   scripts/category-agreement.sh yourtube-categories-1758000000.json
#
# Compiles the app's own YouTubeCategorySignal and YouTubeCategory, so the
# numbers move when the signal does. Written for issue #129; the findings are
# in docs/spikes/129-youtube-category-vs-classifier.md.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/yourtube-category-agreement"
mkdir -p "$OUT"
swiftc -O -o "$OUT/category-agreement" \
  "$ROOT/scripts/category-agreement/main.swift" \
  "$ROOT/YourTube/Shows/EpisodeSignals.swift" \
  "$ROOT/YourTube/Categorize/YouTubeCategory.swift" \
  "$ROOT/YourTube/Categorize/YouTubeCategorySignal.swift" 2>&1 | grep -v ' warning: ' || true
exec "$OUT/category-agreement" "$@"

#!/bin/sh
# Shared body for post-merge / post-checkout / post-rewrite.
# Regenerates the gitignored .xcodeproj when the Swift file set or project.yml
# changed between $1 (old HEAD) and $2 (new HEAD).
set -e
old="$1"; new="$2"
[ -z "$old" ] || [ -z "$new" ] || [ "$old" = "$new" ] && exit 0

if ! git diff --name-only --diff-filter=ADR "$old" "$new" -- project.yml YourTube YourTubeTests \
     | grep -qE '\.swift$|^project\.yml$'; then
  exit 0
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[hook] Swift files changed but xcodegen is not installed (brew install xcodegen); run 'xcodegen generate' manually." >&2
  exit 0
fi

echo "[hook] Swift file set changed; regenerating YourTube.xcodeproj"
xcodegen generate --quiet

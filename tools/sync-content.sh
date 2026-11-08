#!/bin/bash
# Copies the canonical world content (content/) and the compressed art (art/opt/*.jpg) into the iOS app and the website.
# Full-size originals (art/*.png, not in git) are compressed into art/opt by tools/optimize-art.sh.
# Safe to run any time; it only copies. Usage: tools/sync-content.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORLD="$ROOT/content/lantern-bay.json"
JOBS="$ROOT/content/art-jobs.json"
IOS_RES="$ROOT/ios/Hearth/Resources"
WEB="$ROOT/docs"

# Refuse to ship a file that isn't valid JSON (a typo would break both apps).
if command -v python3 > /dev/null; then
  python3 -I -m json.tool "$WORLD" > /dev/null
  python3 -I -m json.tool "$JOBS" > /dev/null
fi

mkdir -p "$IOS_RES/Art" "$WEB/world" "$WEB/assets/art"

cp "$WORLD" "$IOS_RES/lantern-bay.json"
cp "$WORLD" "$WEB/world/lantern-bay.json"
cp "$JOBS" "$IOS_RES/art-jobs.json"

shopt -s nullglob
art=("$ROOT"/art/opt/*.jpg)
if [ ${#art[@]} -gt 0 ]; then
  rm -f "$IOS_RES"/Art/*.png "$WEB"/assets/art/*.png
  cp "${art[@]}" "$IOS_RES/Art/"
  cp "${art[@]}" "$WEB/assets/art/"
fi

echo "sync-content: world + art jobs copied, ${#art[@]} art image(s) copied"

#!/bin/bash
# Compresses the full-size Image Playground art (art/*.png) into art/opt/*.jpg for the app and the website.
# Characters: 640 px, quality 80. Places and heroes: 1024 px, quality 74. Usage: tools/optimize-art.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/art/opt"
shopt -s nullglob
for f in "$ROOT"/art/char-*.png; do
  sips -s format jpeg -s formatOptions 80 -Z 640 "$f" --out "$ROOT/art/opt/$(basename "${f%.png}").jpg" > /dev/null
done
for f in "$ROOT"/art/loc-*.png "$ROOT"/art/hero-*.png; do
  sips -s format jpeg -s formatOptions 74 -Z 1024 "$f" --out "$ROOT/art/opt/$(basename "${f%.png}").jpg" > /dev/null
done
echo "optimize-art: $(ls "$ROOT"/art/opt/*.jpg | wc -l | tr -d ' ') images in art/opt"

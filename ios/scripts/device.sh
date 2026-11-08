#!/bin/bash
# Build, install and run Hearth on the paired iPhone, then pull its dev outputs.
# Usage:
#   ios/scripts/device.sh build                 build a signed Release app for the device
#   ios/scripts/device.sh install               install the last build
#   ios/scripts/device.sh run [launch args...]  launch with console attached (e.g. -HearthBenchmark 1)
#   ios/scripts/device.sh pull                  copy Documents/{tour,bench.jsonl,hearth-console.log} to ios/build/device/
#   ios/scripts/device.sh push-model <file>     copy a Pie model (.metal.zt) into the app's Documents over USB
# DEVICE env var overrides the CoreDevice id.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${DEVICE:-54D718AD-52AF-5D78-8F61-6FDEA525F15E}"
BUNDLE=com.aarushkandukoori.hearth
APP=build/dd/Build/Products/Release-iphoneos/Hearth.app
OUT=build/device

case "${1:-}" in
  build)
    xcodegen > /dev/null
    xcodebuild -project Hearth.xcodeproj -scheme Hearth -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath build/dd -allowProvisioningUpdates -quiet build
    echo "built $APP" ;;
  install)
    xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "App installed|bundleID|ERROR" || true ;;
  run)
    shift
    # App launch arguments must come after "--", or devicectl reads them as its own options.
    xcrun devicectl device process launch --console --terminate-existing --device "$DEVICE" "$BUNDLE" -- "$@" ;;
  pull)
    mkdir -p "$OUT"
    for item in tour bench.jsonl hearth-console.log art; do
      xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source "Documents/$item" --destination "$OUT/$item" > /dev/null 2>&1 \
        && echo "pulled $item" || echo "no $item"
    done ;;
  push-model)
    file="${2:?usage: device.sh push-model <file.metal.zt>}"
    xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source "$file" --destination "Documents/$(basename "$file")" > /dev/null
    echo "pushed $(basename "$file")" ;;
  *)
    sed -n 2,9p "$0"; exit 1 ;;
esac

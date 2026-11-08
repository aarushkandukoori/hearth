#!/bin/bash
# Typecheck Hearth/Core plus the given areas against the iOS Simulator SDK (fast, no Xcode project).
# Usage: ios/scripts/typecheck.sh Engine            (area under ios/Hearth/)
#        ios/scripts/typecheck.sh UI/Chat Store Brain Media UI/Theme
#        DEVICE=1 ios/scripts/typecheck.sh Engine  (iphoneos SDK + llama.framework, compiles the llama code)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${DEVICE:-0}" = "1" ]; then
  SDK=$(xcrun --sdk iphoneos --show-sdk-path); TARGET=arm64-apple-ios26.0
  EXTRA=(-F Vendor/llama.xcframework/ios-arm64)
else
  SDK=$(xcrun --sdk iphonesimulator --show-sdk-path); TARGET=arm64-apple-ios26.0-simulator
  EXTRA=()
fi
files=()
while IFS= read -r f; do files+=("$f"); done < <(find Hearth/Core -name '*.swift' | sort)
for d in "$@"; do
  dir="Hearth/$d"; [ -e "$dir" ] || dir="$d"
  [ -e "$dir" ] || { echo "typecheck: no such file or folder: $d" >&2; exit 2; }
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -name '*.swift' | sort)
done
xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" -swift-version 5 ${EXTRA[@]+"${EXTRA[@]}"} "${files[@]}"
echo "typecheck OK (${#files[@]} files)"

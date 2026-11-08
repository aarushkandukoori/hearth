#!/bin/bash
# Typecheck Hearth/Core plus the given areas against the iOS Simulator SDK (fast, no Xcode project).
# Usage: ios/scripts/typecheck.sh Engine Media      (areas under ios/Hearth/; Engine uses Media)
#        ios/scripts/typecheck.sh Brain Store
#        DEVICE=1 ios/scripts/typecheck.sh Engine Media  (iphoneos SDK instead of the Simulator's)
# Areas may overlap (each file is checked once). The whole app: ios/scripts/typecheck-ui.sh UI App
# Engine/PieEngine.swift imports PieServer, Pie's Swift package in Vendor/PieSwift. When a checked file
# needs it, the package's two modules (PieClient, PieServer) are compiled into a temporary folder first,
# against the C header in Vendor/PieSwift/build/PieServerCore.xcframework. Nothing is linked, so only that
# header matters, but it comes from scripts/build-pie.sh: run that once before checking Engine (or any
# area that pulls it in).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${DEVICE:-0}" = "1" ]; then
  SDK=$(xcrun --sdk iphoneos --show-sdk-path); TARGET=arm64-apple-ios26.0
  SLICE=ios-arm64
else
  SDK=$(xcrun --sdk iphonesimulator --show-sdk-path); TARGET=arm64-apple-ios26.0-simulator
  SLICE=ios-arm64_x86_64-simulator
fi
files=()
while IFS= read -r f; do files+=("$f"); done < <(find Hearth/Core -name '*.swift' | sort)
for d in "$@"; do
  dir="Hearth/$d"; [ -e "$dir" ] || dir="$d"
  [ -e "$dir" ] || { echo "typecheck: no such file or folder: $d" >&2; exit 2; }
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -name '*.swift' | sort)
done
unique=()
while IFS= read -r f; do unique+=("$f"); done < <(printf '%s\n' "${files[@]}" | awk '!seen[$0]++')
files=("${unique[@]}")

EXTRA=()
if grep -q '^import PieServer' "${files[@]}"; then
  pie=Vendor/PieSwift
  headers="$pie/build/PieServerCore.xcframework/$SLICE/Headers"
  if [ ! -f "$headers/pie.h" ]; then
    echo "typecheck: $headers/pie.h is missing. PieEngine.swift needs Pie's Swift package:" >&2
    echo "  PIE_DIR=<pie-project/pie checkout> ios/scripts/build-pie.sh" >&2
    exit 2
  fi
  modules=$(mktemp -d "${TMPDIR:-/tmp}/hearth-typecheck.XXXXXX")
  trap 'rm -rf "${modules:?}"' EXIT
  # Same language mode as the package (swift-tools-version 6.2).
  xcrun swiftc -emit-module -parse-as-library -module-name PieClient -sdk "$SDK" -target "$TARGET" -swift-version 6 \
    -emit-module-path "$modules/PieClient.swiftmodule" "$pie"/Sources/PieClient/*.swift
  xcrun swiftc -emit-module -parse-as-library -module-name PieServer -sdk "$SDK" -target "$TARGET" -swift-version 6 \
    -I "$modules" -I "$headers" -emit-module-path "$modules/PieServer.swiftmodule" "$pie"/Sources/PieServer/*.swift
  EXTRA=(-I "$modules" -I "$headers")
fi

xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" -swift-version 5 ${EXTRA[@]+"${EXTRA[@]}"} "${files[@]}"
echo "typecheck OK (${#files[@]} files)"

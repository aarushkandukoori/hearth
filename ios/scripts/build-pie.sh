#!/usr/bin/env bash
# Builds ios/Vendor/PieSwift/build/PieServerCore.xcframework, the binary half
# of Pie's Swift package:
#   ios-arm64            Pie's C library (runtime, Metal engine, inferlet
#                        sandbox) built from a Pie checkout at the pinned commit,
#                        plus pie-ios-fixes.patch
#   ios-arm64-simulator  a stub (scripts/pie-sim-stub.c): Pie runs on the device
#
#   PIE_DIR=~/src/pie ios/scripts/build-pie.sh      (PIE_DIR at 6168f025d)
# The first build takes about 20 minutes.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ios="$(cd "$here/.." && pwd)"
pie="${PIE_DIR:?set PIE_DIR to a pie-project/pie checkout at 6168f025d}"
want=6168f025d
have="$(git -C "$pie" rev-parse --short=9 HEAD)"
[ "$have" = "$want" ] || echo "warning: $pie is at $have, Hearth is tested with $want" >&2

out="$ios/Vendor/PieSwift/build"
work="$out/work"
mkdir -p "$work/headers" "$work/sim"

# Two one-line fixes Hearth needs on the iPhone, until they are upstream (see pie-ios-fixes.patch):
# a wasm growth reservation that fits an iPhone's address space, and the state-slot commit clamp.
if git -C "$pie" apply --check "$here/pie-ios-fixes.patch" 2>/dev/null; then
  echo "== applying pie-ios-fixes.patch to $pie"
  git -C "$pie" apply "$here/pie-ios-fixes.patch"
elif git -C "$pie" apply --check --reverse "$here/pie-ios-fixes.patch" 2>/dev/null; then
  echo "== pie-ios-fixes.patch already applied"
else
  echo "pie-ios-fixes.patch does not apply to $pie; build without it at your own risk" >&2
  exit 1
fi

echo "== Pie C library for aarch64-apple-ios (release)"
# Inside the Pie checkout, so its rust-toolchain.toml picks the toolchain that gets the iOS target.
(cd "$pie" && rustup target add aarch64-apple-ios >/dev/null && IPHONEOS_DEPLOYMENT_TARGET=26.0 \
  CARGO_TARGET_DIR="$pie/target-apple" cargo build --target aarch64-apple-ios -p pie-c --lib --release)

cp "$pie/packages/c/include/pie.h" "$work/headers/"
cat > "$work/headers/module.modulemap" <<'MAP'
module PieServerCore {
    header "pie.h"
    link "pie"
    export *
}
MAP

echo "== Simulator stub"
for arch in arm64 x86_64; do
  xcrun --sdk iphonesimulator clang -target "$arch-apple-ios26.0-simulator" -O2 \
    -I "$work/headers" -c "$here/pie-sim-stub.c" -o "$work/sim/pie-sim-stub-$arch.o"
done
xcrun --sdk iphonesimulator libtool -static -o "$work/sim/libpie.a" "$work/sim/pie-sim-stub-arm64.o" "$work/sim/pie-sim-stub-x86_64.o"

rm -rf "$out/PieServerCore.xcframework"
xcodebuild -create-xcframework \
  -library "$pie/target-apple/aarch64-apple-ios/release/libpie.a" -headers "$work/headers" \
  -library "$work/sim/libpie.a" -headers "$work/headers" \
  -output "$out/PieServerCore.xcframework" >/dev/null
du -sh "$out/PieServerCore.xcframework"/*/libpie.a
echo "== $out/PieServerCore.xcframework"

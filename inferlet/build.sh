#!/usr/bin/env bash
# Builds Hearth's inferlet twice from one source:
#   iphone  against Pie main (the commit the iPhone app links)   -> ios/Hearth/Resources/Pie/hearth.wasm
#   web     against Pie server-web 0.6.4 (what the site loads)   -> docs/app/pie/hearth.wasm
# Each build points the `inferlet` crate at a local Pie checkout:
#   PIE_IPHONE=~/src/pie-main PIE_WEB=~/src/pie-0.6.4 ./build.sh [iphone|web|both]
set -euo pipefail
cd "$(dirname "$0")"
repo="$(cd .. && pwd)"
which="${1:-both}"

build() { # name pie-checkout output
  local name="$1" pie="$2" dest="$3"
  [ -d "$pie/crates/inferlet" ] || { echo "no Pie checkout at $pie" >&2; exit 1; }
  echo "== $name: inferlet from $pie ($(git -C "$pie" rev-parse --short HEAD))"
  CARGO_TARGET_DIR="target/$name" cargo build --release --target wasm32-wasip3 \
    --config "patch.'https://github.com/pie-project/pie'.inferlet.path='$pie/crates/inferlet'"
  mkdir -p "$(dirname "$dest")"
  cp "target/$name/wasm32-wasip3/release/hearth.wasm" "$dest"
  ls -l "$dest"
}

case "$which" in iphone|web|both) ;; *) echo "usage: $0 [iphone|web|both]" >&2; exit 2 ;; esac
if [ "$which" != web ]; then
  build iphone "${PIE_IPHONE:?set PIE_IPHONE to a Pie checkout at 6168f025d}" "$repo/ios/Hearth/Resources/Pie/hearth.wasm"
fi
if [ "$which" != iphone ]; then
  build web "${PIE_WEB:?set PIE_WEB to a Pie checkout at server-web 0.6.4 (75eb46bd7)}" "$repo/docs/app/pie/hearth.wasm"
fi

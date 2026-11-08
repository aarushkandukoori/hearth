#!/bin/bash
# Builds an UNSIGNED Hearth.ipa for sideloading (AltStore or Sideloadly re-sign it with your Apple ID).
# Output: ios/build/Hearth.ipa, the file name docs/iphone tells people to download from the GitHub release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ios"
xcodegen > /dev/null
xcodebuild -project Hearth.xcodeproj -scheme Hearth -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/unsigned \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet build
APP="build/unsigned/Build/Products/Release-iphoneos/Hearth.app"
STAGE="build/ipa-stage"
rm -rf "${STAGE:?}" && mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
# zip adds to an existing archive, so start fresh or files from an older build stay inside.
rm -f build/Hearth.ipa
(cd "$STAGE" && zip -qry ../Hearth.ipa Payload)
echo "built ios/build/Hearth.ipa ($(du -h build/Hearth.ipa | cut -f1))"

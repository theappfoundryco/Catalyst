#!/usr/bin/env bash
# Build a branded, notarized DMG for hand-install on another Mac (NOT a Sparkle release —
# use Scripts/cut_release.sh for that). Assets live in Scripts/ (VolumeIcon.icns, dmg-background@2x.png).
set -euo pipefail

TEAM_ID="6957JGQD3R"
NOTARY_PROFILE="CATALYST_NOTARY"

cd ~/Desktop/Catalyst
mkdir -p build

# Abort unless the Release config is sane (no Debug leakage, hardened runtime, real signing).
source ~/Desktop/Catalyst/Scripts/preflight_release.sh; preflight_release

rm -rf build/Catalyst.xcarchive build/export
xcodebuild -scheme Catalyst -configuration Release \
  -archivePath build/Catalyst.xcarchive archive \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Catalyst.xcarchive \
  -exportPath build/export -exportOptionsPlist Scripts/exportOptions.plist

rm -f build/Catalyst.dmg
create-dmg \
  --volname "Catalyst" \
  --volicon Scripts/VolumeIcon.icns \
  --background Scripts/dmg-background@2x.png \
  --window-pos 200 120 --window-size 700 460 \
  --icon-size 112 \
  --icon "Catalyst.app" 185 290 \
  --app-drop-link 515 290 \
  --hide-extension "Catalyst.app" \
  build/Catalyst.dmg build/export/Catalyst.app
xcrun notarytool submit build/Catalyst.dmg --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Catalyst.dmg
echo "✅ build/Catalyst.dmg"

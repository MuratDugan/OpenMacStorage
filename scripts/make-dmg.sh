#!/bin/bash
# Builds a polished drag-to-Applications DMG for OpenMacStorage.
#
# Uses `create-dmg` (https://github.com/create-dmg/create-dmg) if available
# — that's a Homebrew formula:  brew install create-dmg
# Falls back to a plain `hdiutil` DMG if create-dmg isn't installed.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

APP="OpenMacStorage.app"
DMG="OpenMacStorage.dmg"
VOL="OpenMacStorage"

# 0. Make sure the app is fresh.
./scripts/make-app.sh

# 1. Wipe any previous DMG/staging.
rm -f "$DMG"
rm -rf dmg-staging
mkdir -p dmg-staging

# 2. Drop the .app in. create-dmg adds the Applications shortcut itself.
cp -R "$APP" "dmg-staging/$APP"

if command -v create-dmg >/dev/null 2>&1; then
  # Branded background (regenerate with scripts/make-dmg-background.swift).
  BG_ARG=()
  if [[ -f "assets/dmg-background.png" ]]; then
    BG_ARG=(--background "assets/dmg-background.png")
  fi
  create-dmg \
    --volname "$VOL" \
    --window-pos 200 120 \
    --window-size 640 400 \
    --icon-size 110 \
    --icon "$APP" 165 200 \
    --hide-extension "$APP" \
    --app-drop-link 475 200 \
    --no-internet-enable \
    "${BG_ARG[@]}" \
    "$DMG" \
    "dmg-staging/" 2>&1 | tail -8
else
  # Plain DMG fallback: shows the .app and an Applications symlink side-by-side.
  ln -s /Applications dmg-staging/Applications
  hdiutil create \
    -volname "$VOL" \
    -srcfolder dmg-staging \
    -ov -format UDZO \
    "$DMG"
fi

rm -rf dmg-staging

# 3. Sign + notarize + staple, so Gatekeeper opens it without warnings.
IDENTITY=$(signing_identity)
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "• Notarizing (usually 1–5 minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" || true
  else
    echo "• Skipped notarization: no keychain profile \"$NOTARY_PROFILE\"."
    echo "  One-time setup:"
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <TEAM_ID>"
  fi
fi

SIZE=$(du -h "$DMG" | cut -f1)
echo "✓ $DMG ready ($SIZE)."
echo "  Open with: open $DMG"

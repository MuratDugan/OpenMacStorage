#!/bin/bash
# Wraps the Swift Package binary into a proper .app bundle, including localization resources.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

BIN=".build/release/OpenMacStorage"
BUILD_BUNDLE_PARENT=".build/release"
APP="OpenMacStorage.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/OpenMacStorage"

# App icon — generated from OpenMacStorage-1024.png via iconutil.
if [[ -f "AppIcon.icns" ]]; then
  cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM emits a localized resource bundle; copy each .lproj into the .app.
RES_BUNDLE=$(ls -d "$BUILD_BUNDLE_PARENT"/*_OpenMacStorage.bundle 2>/dev/null | head -n 1 || true)
if [[ -n "$RES_BUNDLE" && -d "$RES_BUNDLE/Contents/Resources" ]]; then
  cp -R "$RES_BUNDLE/Contents/Resources/"*.lproj "$APP/Contents/Resources/" 2>/dev/null || true
fi

# Fallback: copy directly from sources.
for d in Sources/OpenMacStorage/Resources/*.lproj; do
  [[ -d "$d" ]] || continue
  cp -R "$d" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>OpenMacStorage</string>
  <key>CFBundleDisplayName</key>      <string>OpenMacStorage</string>
  <key>CFBundleIdentifier</key>       <string>com.muratdugan.openmacstorage</string>
  <key>CFBundleVersion</key>          <string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key>       <string>OpenMacStorage</string>
  <key>CFBundleIconFile</key>         <string>AppIcon</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSPrincipalClass</key>         <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key> <string>© 2026 Murat Duğan. MIT License.</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>tr</string>
    <string>zh-Hans</string>
    <string>es</string>
    <string>pt-BR</string>
    <string>ru</string>
    <string>de</string>
    <string>fr</string>
    <string>ja</string>
  </array>
</dict>
</plist>
PLIST

echo "✓ $APP ready."
echo "Open with: open $APP"

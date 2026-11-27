#!/bin/zsh
# Builds Calendar Clock.app (Apple Silicon).
#   zsh build.sh           installs it in ~/Applications and launches it
#   zsh build.sh release   makes dist/CalendarClock-<version>.dmg for a GitHub Release
# Needs only Apple's Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"

BUNDLE_ID="${BUNDLE_ID:-io.github.tobyadams87.calendarclock}"
VERSION="1.0.0"
if [[ "$1" == "release" ]]; then
  # Assembled outside iCloud Drive: its file metadata makes code signing fail.
  STAGE="$(mktemp -d)/Calendar Clock"
  rm -rf dist && mkdir -p dist
  APP="$STAGE/Calendar Clock.app"
else
  APP="$HOME/Applications/Calendar Clock.app"
fi

echo "Compiling…"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/CalendarClock" CalendarClock.swift
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Calendar Clock</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>CalendarClock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Toby Adams. MIT License.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Used to show the day you click in the Calendar app.</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
  <string>Calendar asks for this before it will show the day you click. Calendar Clock never reads or changes your events.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with a stable designated requirement (the bundle identifier), so macOS
# keeps permissions such as "control Calendar" across rebuilds instead of tying them to
# this exact build's code hash.
xattr -cr "$APP"
codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"

if [[ "$1" == "release" ]]; then
  # A disk image with the app and a shortcut to Applications to drag it into.
  ln -s /Applications "$STAGE/Applications"
  DMG="dist/CalendarClock-$VERSION.dmg"
  hdiutil create -quiet -volname "Calendar Clock" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
  rm -rf "$(dirname "$STAGE")"
  echo "Release disk image: $DMG"
  exit 0
fi

pkill -x CalendarClock || true
open "$APP"
echo "Installed and launched: $APP"

#!/bin/bash
set -euo pipefail

APP_NAME="Claudio"
SIGNING_IDENTITY="Developer ID Application: Matt Jakob (TXY9794V3B)"
NOTARIZE_PROFILE="Claudio-notarize"

# Auto-increment version from latest git tag (v1.2.3 → 1.2.4), or start at 1.0.0
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
MAJOR=$(echo "$LATEST_TAG" | sed 's/^v//' | cut -d. -f1)
MINOR=$(echo "$LATEST_TAG" | sed 's/^v//' | cut -d. -f2)
PATCH=$(echo "$LATEST_TAG" | sed 's/^v//' | cut -d. -f3)
PATCH=$((PATCH + 1))
VERSION="${1:-$MAJOR.$MINOR.$PATCH}"

BUILD_DIR=".build/arm64-apple-macosx/release"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="${APP_NAME}.dmg"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG_DIR="$REPO_ROOT"

echo "==> Building release..."
swift build -c release

echo "==> Constructing app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/Claudio" "$APP_DIR/Contents/MacOS/Claudio"
cp Claudio/Info.plist "$APP_DIR/Contents/Info.plist"
cp "$BUILD_DIR/Claudio_Claudio.bundle/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# Include SPM resource bundle
cp -R "$BUILD_DIR/Claudio_Claudio.bundle" "$APP_DIR/Contents/Resources/"

# Stamp version into bundle
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
BUNDLE_VERSION=$(echo "$VERSION" | tr -d '.')
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$APP_DIR/Contents/Info.plist"

echo "==> Signing with Developer ID + hardened runtime..."
codesign --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements Claudio/Claudio.entitlements \
    "$APP_DIR"

echo "==> Verifying signature..."
codesign -vvv --deep --strict "$APP_DIR"
spctl --assess -vvv "$APP_DIR" 2>&1 || true

echo "==> Creating DMG..."
mkdir -p "$DMG_DIR"
rm -f "$DMG_DIR/$DMG_NAME"

VOL_NAME="Install $APP_NAME"
RW_DMG="$BUILD_DIR/${APP_NAME}-rw.dmg"
rm -f "$RW_DMG"

# Create a read-write DMG large enough for the app
hdiutil create -size 200m -fs HFS+ -volname "$VOL_NAME" -ov "$RW_DMG"

# Mount it
DEVICE=$(hdiutil attach "$RW_DMG" -nobrowse -noverify | tail -1 | awk '{print $1}')
MOUNT_POINT="/Volumes/$VOL_NAME"

# Copy app and create Finder alias for Applications
cp -R "$APP_DIR" "$MOUNT_POINT/"
osascript -e "tell application \"Finder\" to make alias file to POSIX file \"/Applications\" at POSIX file \"$MOUNT_POINT\""

# Set the /Applications folder icon on the alias (macOS 26 doesn't resolve it automatically)
osascript << ICONEOF
use framework "AppKit"
set ws to current application's NSWorkspace's sharedWorkspace()
set appIcon to ws's iconForFile:"/Applications"
ws's setIcon:appIcon forFile:"$MOUNT_POINT/Applications" options:0
ICONEOF

# Generate background image with drag arrow
echo "==> Generating DMG background..."
mkdir -p "$MOUNT_POINT/.background"
python3 - "$MOUNT_POINT/.background/arrow.png" << 'PYEOF'
import sys
from PIL import Image, ImageDraw

W, H = 540, 380
img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Arrow between the two icons (horizontally centered between them)
y = 190
x1, x2 = 230, 330
color = (255, 255, 255, 80)

# Shaft
draw.line([(x1, y), (x2 - 14, y)], fill=color, width=3)

# Arrowhead
draw.polygon([(x2, y), (x2 - 18, y - 11), (x2 - 18, y + 11)], fill=color)

img.save(sys.argv[1])
PYEOF

# Style the DMG window with AppleScript
echo "==> Styling DMG window..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 640, 480}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:arrow.png"
        set position of item "$APP_NAME.app" of container window to {130, 185}
        set position of item "Applications" of container window to {410, 185}
        close
        open
        update without registering applications
    end tell
end tell
APPLESCRIPT

# Let Finder write .DS_Store
sync
sleep 2

# Unmount
hdiutil detach "$DEVICE"

# Convert to compressed read-only DMG
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_DIR/$DMG_NAME"
rm -f "$RW_DMG"

echo "==> Signing DMG..."
codesign --sign "$SIGNING_IDENTITY" "$DMG_DIR/$DMG_NAME"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$DMG_DIR/$DMG_NAME" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_DIR/$DMG_NAME"

echo "==> Creating GitHub release v$VERSION..."
TAG="v$VERSION"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$DMG_DIR/$DMG_NAME" \
    --title "$APP_NAME $TAG" \
    --notes "Release $TAG" \
    --latest

echo ""
echo "Done! DMG: $DMG_DIR/$DMG_NAME"
echo "Release: https://github.com/mattjakob/jkbClaudio/releases/tag/$TAG"

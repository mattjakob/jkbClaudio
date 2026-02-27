#!/bin/bash
set -euo pipefail

APP_NAME="Claude Widget"
BUNDLE_ID="com.mattjakob.ClaudeWidget"
BUILD_DIR=".build/arm64-apple-macosx/debug"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

swift build

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/ClaudeWidget" "$APP_DIR/Contents/MacOS/ClaudeWidget"
cp ClaudeWidget/Info.plist "$APP_DIR/Contents/Info.plist"
cp "$BUILD_DIR/ClaudeWidget_ClaudeWidget.bundle/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Add CFBundleIdentifier to Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ClaudeWidget" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ClaudeWidget" "$APP_DIR/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP_DIR/Contents/Info.plist"

# Sign with entitlements
codesign --force --sign - --entitlements ClaudeWidget/ClaudeWidget.entitlements "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""

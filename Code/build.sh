#!/bin/bash
set -euo pipefail

APP_NAME="Claudio"
BUILD_DIR=".build/arm64-apple-macosx/debug"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

swift build

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/Claudio" "$APP_DIR/Contents/MacOS/Claudio"
cp Claudio/Info.plist "$APP_DIR/Contents/Info.plist"
cp "$BUILD_DIR/Claudio_Claudio.bundle/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$BUILD_DIR/Claudio_Claudio.bundle" "$APP_DIR/Contents/Resources/"

codesign --force --sign - --entitlements Claudio/Claudio.entitlements "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""

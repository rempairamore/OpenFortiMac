#!/bin/bash
# Build script for OpenFortiMac
# Creates .app bundle and .dmg installer

set -e

APP_NAME="OpenFortiMac"
BUILD_DIR="build"
DMG_DIR="dmg_contents"

# Version comes from MARKETING_VERSION in the Xcode project
VERSION=$(xcodebuild -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')

if [ -z "$VERSION" ]; then
    echo "❌ Could not read MARKETING_VERSION from the Xcode project"
    exit 1
fi

DMG_NAME="${APP_NAME}_v${VERSION}.dmg"

echo "🔧 Building $APP_NAME $VERSION..."

# Clean previous builds
rm -rf "$BUILD_DIR"
rm -rf "$DMG_DIR"
rm -f "$DMG_NAME"

# Build the app with symbols stripped
echo "📦 Compiling..."
xcodebuild -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    STRIP_INSTALLED_PRODUCT=YES \
    DEPLOYMENT_POSTPROCESSING=YES \
    DEAD_CODE_STRIPPING=YES \
    DEBUG_INFORMATION_FORMAT=dwarf \
    GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
    SWIFT_COMPILATION_MODE=wholemodule \
    build

# Find the built app
APP_PATH=$(find "$BUILD_DIR" -name "$APP_NAME.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Build failed: $APP_NAME.app not found"
    exit 1
fi

echo "✅ Build successful"

# Create DMG
echo "💿 Creating DMG..."

mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_NAME"

rm -rf "$DMG_DIR"

SHA256=$(shasum -a 256 "$DMG_NAME" | awk '{print $1}')

echo ""
echo "✅ Done! Created: $DMG_NAME"
echo ""
echo "Homebrew cask values (homebrew-tap/Casks/openfortimac.rb):"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA256\""

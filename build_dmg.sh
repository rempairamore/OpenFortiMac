#!/bin/bash
# Build script for OpenFortiMac
# Creates .app bundle and .dmg installer

set -e

APP_NAME="OpenFortiMac"
BUILD_DIR="build"
DMG_DIR="dmg_contents"

# Stable self-signed certificate: keeps the app's identity (and its Keychain access)
# the same across updates. Without it the build falls back to an ad-hoc signature.
SIGN_NAME="OpenFortiMac Self-Signed"

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

# Build a universal (arm64 + x86_64) app with symbols stripped.
# Ad-hoc signing needs no certificate, so the same build runs locally and on CI.
echo "📦 Compiling..."
xcodebuild -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
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

# Re-sign with the self-signed certificate when it is on the keychain search list.
# Looked up by hash because codesign rejects untrusted certificates by name.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$SIGN_NAME\"" 'index($0, name) {print $2; exit}')}"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔏 Signing with \"$SIGN_NAME\" ($SIGN_IDENTITY)..."
    codesign --force --options runtime --timestamp=none \
        --preserve-metadata=entitlements \
        --sign "$SIGN_IDENTITY" "$APP_PATH"
else
    echo "⚠️  \"$SIGN_NAME\" not found in the keychain: ad-hoc signature."
    echo "    Users will get a Keychain prompt after updating to this build."
fi
codesign --verify --deep --strict "$APP_PATH"

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

# Hand the results to the next GitHub Actions steps
if [ -n "$GITHUB_OUTPUT" ]; then
    {
        echo "version=$VERSION"
        echo "dmg=$DMG_NAME"
        echo "sha256=$SHA256"
        echo "app=$APP_PATH"
        echo "signed=$([ -n "$SIGN_IDENTITY" ] && echo true || echo false)"
    } >> "$GITHUB_OUTPUT"
fi

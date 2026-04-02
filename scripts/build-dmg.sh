#!/bin/bash
# build-dmg.sh — Build Coach Alfred as a DMG installer
# Usage: ./scripts/build-dmg.sh [--skip-build]
set -e

VERSION="2.2.0"
APP_NAME="Alfred"
BUNDLE_ID="com.msfoundry.alfred"
DMG_NAME="Coach-Alfred-${VERSION}.dmg"
BUILD_DIR=".build/release"
STAGING_DIR="/tmp/alfred-dmg-staging"
APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"

echo "🎩 Building Coach Alfred v${VERSION} DMG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Build (unless --skip-build)
if [[ "$1" != "--skip-build" ]]; then
    echo "📦 Building release binary..."
    swift build -c release
    echo "✓ Build complete"
    echo ""
fi

# Verify binary exists
if [[ ! -f "${BUILD_DIR}/${APP_NAME}" ]]; then
    echo "❌ Binary not found at ${BUILD_DIR}/${APP_NAME}"
    echo "   Run 'swift build -c release' first"
    exit 1
fi

# Step 2: Create app bundle structure
echo "📁 Creating app bundle..."
rm -rf "${STAGING_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Coach Alfred</string>
    <key>CFBundleDisplayName</key>
    <string>Coach Alfred</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 MS Foundry. All rights reserved.</string>
</dict>
</plist>
PLIST

# Copy web resources
if [[ -f "Sources/GUI/Resources/home.html" ]]; then
    cp Sources/GUI/Resources/home.html "${APP_BUNDLE}/Contents/Resources/"
fi

# Copy PWA resources (service worker, manifest, icons)
mkdir -p "${APP_BUNDLE}/Contents/Resources/web"
for f in sw.js manifest.json icon-192.png icon-512.png; do
    if [[ -f "Sources/GUI/Resources/${f}" ]]; then
        cp "Sources/GUI/Resources/${f}" "${APP_BUNDLE}/Contents/Resources/web/"
    elif [[ -f "${HOME}/.config/alfred/web/${f}" ]]; then
        cp "${HOME}/.config/alfred/web/${f}" "${APP_BUNDLE}/Contents/Resources/web/"
    fi
done

# Copy LaunchAgent plist template
if [[ -f "Config/com.msfoundry.alfred.plist" ]]; then
    cp Config/com.msfoundry.alfred.plist "${APP_BUNDLE}/Contents/Resources/"
fi

# Copy example skills
if [[ -d "Config/example-skills" ]]; then
    cp -r Config/example-skills "${APP_BUNDLE}/Contents/Resources/"
fi

# Copy example config
if [[ -f "Config/config.example.json" ]]; then
    cp Config/config.example.json "${APP_BUNDLE}/Contents/Resources/"
fi

echo "✓ App bundle created"

# Step 3: Codesign
echo "🔏 Signing..."
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
echo "✓ Signed with identifier ${BUNDLE_ID}"

# Step 4: Create DMG
echo "💿 Creating DMG..."

# Remove existing DMG
rm -f "${DMG_NAME}"

# Create DMG with Applications symlink for drag-to-install
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
    -volname "Coach Alfred ${VERSION}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

echo "✓ DMG created: ${DMG_NAME}"
echo ""

# Cleanup
rm -rf "${STAGING_DIR}"

# Print DMG info
DMG_SIZE=$(du -h "${DMG_NAME}" | cut -f1)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Coach Alfred v${VERSION}"
echo "   File: ${DMG_NAME}"
echo "   Size: ${DMG_SIZE}"
echo ""
echo "To install:"
echo "   1. Open ${DMG_NAME}"
echo "   2. Drag Alfred.app to Applications"
echo "   3. Open Alfred.app — setup wizard starts automatically"
echo "   4. Grant Full Disk Access in System Settings"

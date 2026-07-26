#!/bin/bash
# build-dmg.sh — Build Coach Alfred as a signed, notarized DMG installer
#
# Modes (auto-detected):
#   1. Distribution mode (PREFERRED for shipping to users):
#      - Set DEVELOPER_ID env var to your Developer ID Application identity name
#      - Set NOTARY_PROFILE env var to the keychain profile name from `notarytool store-credentials`
#      - Script will: hardened-runtime sign → notarize → staple → sign + notarize the DMG
#
#   2. Local/dev mode (fallback when env vars are missing):
#      - Falls back to ad-hoc signing with a loud warning
#      - DMG will trip Gatekeeper on other Macs — only useful for local testing
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (YOUR_TEAM_ID)" \
#   NOTARY_PROFILE="alfred-notary" \
#   ./scripts/build-dmg.sh [--skip-build] [--skip-notarize]
set -e

VERSION="3.0.0"
APP_NAME="Alfred"
BUNDLE_ID="com.msfoundry.alfred"
DMG_NAME="Coach-Alfred-${VERSION}.dmg"
BUILD_DIR=".build/release"
STAGING_DIR="/tmp/alfred-dmg-staging"
APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"
ENTITLEMENTS="Config/Alfred.entitlements"

SKIP_BUILD=0
SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-build)    SKIP_BUILD=1 ;;
        --skip-notarize) SKIP_NOTARIZE=1 ;;
    esac
done

# Detect signing mode
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    SIGN_MODE="distribution"
    SIGN_IDENTITY="${DEVELOPER_ID}"
else
    SIGN_MODE="adhoc"
    SIGN_IDENTITY="-"
    echo "⚠️  WARNING: DEVELOPER_ID not set — falling back to ad-hoc signing."
    echo "   This DMG will trip Gatekeeper on other Macs."
    echo "   For distribution, export DEVELOPER_ID and NOTARY_PROFILE first."
    echo ""
fi

echo "🎩 Building Coach Alfred v${VERSION} DMG"
echo "   mode: ${SIGN_MODE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Build (unless --skip-build)
if [[ "${SKIP_BUILD}" == "0" ]]; then
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
# NSContactsUsageDescription is required because the app calls CNContactStore.
# Full Disk Access (for iMessage chat.db) is granted via System Settings — no plist key needed.
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
    <key>NSContactsUsageDescription</key>
    <string>Alfred reads your Contacts to recognise the people in your messages and calendar so it can coach you on relationships.</string>
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
echo ""

# Step 3: Codesign
echo "🔏 Signing app bundle..."
if [[ "${SIGN_MODE}" == "distribution" ]]; then
    if [[ ! -f "${ENTITLEMENTS}" ]]; then
        echo "❌ Entitlements file missing at ${ENTITLEMENTS}"
        exit 1
    fi
    # Hardened runtime + entitlements + timestamp — required for notarization
    codesign --force --deep \
        --sign "${SIGN_IDENTITY}" \
        --identifier "${BUNDLE_ID}" \
        --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        --timestamp \
        "${APP_BUNDLE}"
    echo "✓ Signed with: ${SIGN_IDENTITY}"

    # Verify the signature is well-formed before we waste time uploading to Apple
    echo "🔎 Verifying signature..."
    codesign --verify --strict --verbose=2 "${APP_BUNDLE}"
    echo "✓ Signature verified"
else
    codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    echo "✓ Ad-hoc signed (not for distribution)"
fi
echo ""

# Step 4: Notarize the app (only in distribution mode)
if [[ "${SIGN_MODE}" == "distribution" && "${SKIP_NOTARIZE}" == "0" ]]; then
    if [[ -z "${NOTARY_PROFILE:-}" ]]; then
        echo "⚠️  NOTARY_PROFILE not set — skipping notarization."
        echo "   To notarize, run:"
        echo "     xcrun notarytool store-credentials \"alfred-notary\" \\"
        echo "       --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-pw>"
        echo "   then re-run with NOTARY_PROFILE=alfred-notary"
        echo ""
    else
        echo "📤 Notarizing app bundle (this takes 1–10 minutes)..."
        APP_ZIP="${STAGING_DIR}/${APP_NAME}-notarize.zip"
        ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_ZIP}"
        xcrun notarytool submit "${APP_ZIP}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait
        rm -f "${APP_ZIP}"
        echo "✓ App notarized"

        echo "📎 Stapling ticket to app bundle..."
        xcrun stapler staple "${APP_BUNDLE}"
        xcrun stapler validate "${APP_BUNDLE}"
        echo "✓ Stapled"
        echo ""
    fi
fi

# Step 5: Create DMG
echo "💿 Creating DMG..."
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

# Step 6: Sign + notarize the DMG itself (distribution mode only)
if [[ "${SIGN_MODE}" == "distribution" ]]; then
    echo "🔏 Signing DMG..."
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_NAME}"
    echo "✓ DMG signed"

    if [[ "${SKIP_NOTARIZE}" == "0" && -n "${NOTARY_PROFILE:-}" ]]; then
        echo "📤 Notarizing DMG (this takes 1–10 minutes)..."
        xcrun notarytool submit "${DMG_NAME}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait
        echo "✓ DMG notarized"

        echo "📎 Stapling ticket to DMG..."
        xcrun stapler staple "${DMG_NAME}"
        xcrun stapler validate "${DMG_NAME}"
        echo "✓ Stapled"
    fi
    echo ""
fi

# Cleanup
rm -rf "${STAGING_DIR}"

# Print DMG info
DMG_SIZE=$(du -h "${DMG_NAME}" | cut -f1)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Coach Alfred v${VERSION}"
echo "   File: ${DMG_NAME}"
echo "   Size: ${DMG_SIZE}"
echo "   Mode: ${SIGN_MODE}"
echo ""
echo "To install:"
echo "   1. Open ${DMG_NAME}"
echo "   2. Drag Alfred.app to Applications"
echo "   3. Open Alfred.app — setup wizard starts automatically"
echo "   4. Grant Full Disk Access in System Settings"

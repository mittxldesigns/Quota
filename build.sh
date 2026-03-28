#!/bin/bash
set -e

APP_NAME="Quota"
DISPLAY_NAME="Quota"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_NAME}.app"
VERSION="1.1.0"

echo "==> Building ${DISPLAY_NAME} v${VERSION}..."

# Clean
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Get SDK path
SDK=$(xcrun --show-sdk-path --sdk macosx)
ARCH=$(uname -m)

echo "    SDK: ${SDK}"
echo "    Arch: ${ARCH}"

# Compile
swiftc \
    -parse-as-library \
    -sdk "${SDK}" \
    -target "${ARCH}-apple-macos14.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Security \
    -framework ServiceManagement \
    -framework UserNotifications \
    -O \
    -o "${BUILD_DIR}/${APP_NAME}" \
    Sources/*.swift

echo "==> Creating app bundle..."

mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

mv "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp Info.plist "${APP_BUNDLE}/Contents/"

# Copy icon if it exists
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "${APP_BUNDLE}/Contents/Resources/"
    echo "    Icon: AppIcon.icns"
fi

# Ad-hoc code sign
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true

echo "==> Build complete: ${APP_BUNDLE}"

# Install to /Applications (opt-in with --install flag)
if [[ "$1" == "--install" ]]; then
    echo "==> Installing to /Applications..."
    pkill -f "${APP_NAME}" 2>/dev/null || true
    sleep 0.3
    rm -rf "${INSTALL_PATH}"
    cp -r "${APP_BUNDLE}" "${INSTALL_PATH}"
    echo "==> Installed at ${INSTALL_PATH}"
fi

# Create distributable DMG
if command -v hdiutil &>/dev/null; then
    echo "==> Creating DMG..."
    DMG_DIR="${BUILD_DIR}/dmg_staging"
    DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

    rm -rf "${DMG_DIR}" "${DMG_PATH}"
    mkdir -p "${DMG_DIR}"
    cp -r "${APP_BUNDLE}" "${DMG_DIR}/"

    # Create Applications symlink for drag-to-install
    ln -s /Applications "${DMG_DIR}/Applications"

    # Include install helper script
    if [ -f "Install Quota.command" ]; then
        cp "Install Quota.command" "${DMG_DIR}/"
        chmod +x "${DMG_DIR}/Install Quota.command"
    fi

    hdiutil create \
        -volname "${DISPLAY_NAME}" \
        -srcfolder "${DMG_DIR}" \
        -ov -format UDZO \
        "${DMG_PATH}" \
        2>/dev/null

    rm -rf "${DMG_DIR}"
    echo "==> DMG: ${DMG_PATH}"
fi

# Create .pkg installer (recommended for distribution)
if command -v pkgbuild &>/dev/null; then
    echo "==> Creating PKG installer..."
    PKG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.pkg"
    PKG_ROOT="${BUILD_DIR}/pkg_root"
    PKG_PLIST="${BUILD_DIR}/component.plist"

    # Stage app in a clean root directory
    rm -rf "${PKG_ROOT}"
    mkdir -p "${PKG_ROOT}/Applications"
    cp -R "${APP_BUNDLE}" "${PKG_ROOT}/Applications/"

    # Create component plist that disables relocation
    cat > "${PKG_PLIST}" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <false/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
        <key>RootRelativeBundlePath</key>
        <string>Applications/Quota.app</string>
    </dict>
</array>
</plist>
PLISTEOF

    pkgbuild \
        --root "${PKG_ROOT}" \
        --component-plist "${PKG_PLIST}" \
        --scripts "installer/scripts" \
        --identifier "com.tanishmittal.quota" \
        --version "${VERSION}" \
        "${PKG_PATH}" \
        2>/dev/null

    rm -rf "${PKG_ROOT}" "${PKG_PLIST}"
    echo "==> PKG: ${PKG_PATH}"
fi

echo ""
echo "To test:    open ${APP_BUNDLE}"
echo "To install: bash build.sh --install"

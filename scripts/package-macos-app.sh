#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Hermes Launcher"
PRODUCT_NAME="HermesMacLauncherApp"
SCRIPT_NAME="HermesMacGuiLauncher.command"
DOWNLOADS_DIR="$ROOT_DIR/downloads"
BUILD_DIR="$ROOT_DIR/.build"
APP_BUILD_DIR="$BUILD_DIR/package/macos"
APP_BUNDLE="$APP_BUILD_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$BUILD_DIR/x86_64-apple-macosx/release/$PRODUCT_NAME"
LAUNCHER_SCRIPT="$ROOT_DIR/$SCRIPT_NAME"

version_line="$(grep -E '^LAUNCHER_VERSION=' "$LAUNCHER_SCRIPT" | head -n 1 || true)"
version="${version_line#LAUNCHER_VERSION=\"}"
version="${version%\"}"
version_slug="$(printf '%s' "$version" | sed -E 's/^macOS v//; s/[^0-9.]+/-/g')"

if [[ -z "$version" || -z "$version_slug" ]]; then
  echo "Could not determine launcher version from $SCRIPT_NAME" >&2
  exit 1
fi

rm -rf "$APP_BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$DOWNLOADS_DIR"

swift build -c release --package-path "$ROOT_DIR"

cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
cp "$LAUNCHER_SCRIPT" "$APP_BUNDLE/Contents/Resources/$SCRIPT_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME" "$APP_BUNDLE/Contents/Resources/$SCRIPT_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.ygzhao.hermes-launcher</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version_slug</string>
  <key>CFBundleVersion</key>
  <string>$version_slug</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"

VERSIONED_ZIP="$DOWNLOADS_DIR/Hermes-macOS-Launcher-v$version_slug.zip"
LATEST_ZIP="$DOWNLOADS_DIR/Hermes-macOS-Launcher.zip"
LATEST_TAR="$DOWNLOADS_DIR/Hermes-macOS-Launcher.tar.gz"

rm -f "$VERSIONED_ZIP" "$LATEST_ZIP" "$LATEST_TAR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$VERSIONED_ZIP"
cp "$VERSIONED_ZIP" "$LATEST_ZIP"
tar -C "$APP_BUILD_DIR" -czf "$LATEST_TAR" "$APP_NAME.app"

echo "Built app bundle: $APP_BUNDLE"
echo "Created ZIP: $VERSIONED_ZIP"
echo "Created ZIP alias: $LATEST_ZIP"
echo "Created tar.gz alias: $LATEST_TAR"

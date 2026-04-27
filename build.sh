#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: xcodebuild not available. Install Xcode from the App Store and run:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

rm -rf ./build

xcodebuild \
    -project docstat.xcodeproj \
    -scheme docstat \
    -configuration Release \
    -derivedDataPath ./build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    build

APP="./build/Build/Products/Release/docstat.app"
DEST="/Applications/docstat.app"

if [ ! -d "$APP" ]; then
    echo "error: build did not produce $APP"
    exit 1
fi

if [ -d "$DEST" ]; then
    if pgrep -x docstat >/dev/null; then
        echo "stopping running docstat..."
        pkill -x docstat || true
        sleep 1
    fi
    rm -rf "$DEST"
fi

cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "installed: $DEST"
echo "launch with: open '$DEST'"

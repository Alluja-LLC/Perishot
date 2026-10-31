#!/bin/bash
# Archive, sign with Developer ID, notarize, staple, and zip for distribution.
#
# One-time setup:
#   1. Create a Developer ID Application certificate for the team (Xcode → Settings → Accounts).
#   2. xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \
#        --apple-id <apple-id> --team-id "$TEAM_ID" --password <app-specific-password>
set -euo pipefail

TEAM_ID="${TEAM_ID:-Z74U5327X4}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-alluja-notary}"
SCHEME="perishot"
APP_NAME="perishot.app"

cd "$(dirname "$0")/.."
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/perishot.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ZIP="$BUILD_DIR/perishot.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving"
xcodebuild archive \
    -project perishot.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID"

cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM_ID</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF

echo "==> Exporting"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

echo "==> Notarizing"
ditto -c -k --keepParent "$EXPORT_DIR/$APP_NAME" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$EXPORT_DIR/$APP_NAME"
xcrun stapler validate "$EXPORT_DIR/$APP_NAME"

# Re-zip so the distributed copy carries the stapled ticket.
rm "$ZIP"
ditto -c -k --keepParent "$EXPORT_DIR/$APP_NAME" "$ZIP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$EXPORT_DIR/$APP_NAME"
spctl --assess --type execute --verbose=2 "$EXPORT_DIR/$APP_NAME"

echo "==> Done: $ZIP"

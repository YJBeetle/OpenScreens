#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-}"

if [[ -z "$PROFILE" ]]; then
  echo "usage: $0 <notarytool keychain profile>" >&2
  echo "store one with: xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>" >&2
  exit 1
fi

IDENTITY="${DEVELOPER_ID_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  echo "set DEVELOPER_ID_IDENTITY to a 'Developer ID Application: ...' identity" >&2
  exit 1
fi

DD="$ROOT/var/dd-macos-release"
APP="$DD/Build/Products/Release/OpenScreens.app"
ZIP="$ROOT/var/OpenScreens-macos.zip"

cd "$ROOT/apps/macos"
xcodegen generate >/dev/null
xcodebuild -project OpenScreens.xcodeproj -scheme OpenScreens -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$DD" \
  OPENSCREENS_BUILD_VERSION="$(git -C "$ROOT" describe --tags --always --dirty)" build

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

echo "Signed and notarized: $APP"

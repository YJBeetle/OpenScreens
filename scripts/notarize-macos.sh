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

DD="$WORKSPACE/var/dd-macos-release"
APP="$DD/Build/Products/Release/ScrctlGui.app"
ZIP="$WORKSPACE/var/ScrctlGui-macos.zip"
mkdir -p "$WORKSPACE/var"

tag="$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || printf 'v0.1.0')"
marketing="${tag#v}"

cd "$ROOT/apps/macos"
xcodegen generate >/dev/null
xcodebuild -project ScrctlGui.xcodeproj -scheme ScrctlGui -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$DD" \
  MARKETING_VERSION="${marketing%%-*}" \
  OPENSCREENS_BUILD_VERSION="$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --always)" \
  CURRENT_PROJECT_VERSION="$(git -C "$ROOT" rev-list --count HEAD)" build

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  for nested in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
fi
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

echo "Signed and notarized: $APP"

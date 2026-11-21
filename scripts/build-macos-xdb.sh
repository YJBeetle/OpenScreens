#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/vendor/scrctl/core"
OUT="$ROOT/apps/apple/OpenScreensXdb"
XDB_LIB_DIR="${XDB_LIB_DIR:-$(brew --prefix xdb)/lib}"
export XDB_LIB_DIR MACOSX_DEPLOYMENT_TARGET=15.0
export CFLAGS_aarch64_apple_darwin="${CFLAGS_aarch64_apple_darwin:--mmacosx-version-min=15.0}"
if command -v rustup >/dev/null 2>&1; then
  export PATH="$(dirname "$(rustup which rustc)"):$PATH"
fi

cd "$CORE"
cargo build --locked --release --target aarch64-apple-darwin -p xdb-ffi --features xdb
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cargo run --locked -p rfb-ffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/libxdb_ffi.dylib \
  --language swift --out-dir "$stage" --no-format
framework="$stage/xdb_ffiFFI.framework"
mkdir -p "$framework/Versions/A/"{Headers,Modules,Resources}
ln -s A "$framework/Versions/Current"
for component in Headers Modules Resources xdb_ffiFFI; do
  ln -s "Versions/Current/$component" "$framework/$component"
done
cp "$stage/xdb_ffiFFI.h" "$framework/Headers/"
# A framework keeps this module map separate from the existing RFB headers.
sed 's/^module /framework module /' "$stage/xdb_ffiFFI.modulemap" > "$framework/Modules/module.modulemap"
cp target/aarch64-apple-darwin/release/libxdb_ffi.a "$framework/xdb_ffiFFI"
cat > "$framework/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.scrctl.xdb-ffi</string>
<key>CFBundleExecutable</key><string>xdb_ffiFFI</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
xcodebuild -create-xcframework -framework "$framework" -output "$stage/XdbCore.xcframework"

mkdir -p "$OUT/Sources/OpenScreensXdb" "$OUT/runtime"
cp "$stage/xdb_ffi.swift" "$OUT/Sources/OpenScreensXdb/"
rm -rf "$OUT/XdbCore.xcframework"
mv "$stage/XdbCore.xcframework" "$OUT/"
cp -L "$XDB_LIB_DIR/libxdb_client.1.dylib" "$OUT/runtime/"
chmod u+w "$OUT/runtime/libxdb_client.1.dylib"
install_name_tool -id '@rpath/libxdb_client.1.dylib' "$OUT/runtime/libxdb_client.1.dylib"
codesign --force --sign - "$OUT/runtime/libxdb_client.1.dylib"

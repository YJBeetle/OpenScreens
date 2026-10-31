#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/apps/apple/OpenScreensCore"
HEADERS="$CORE/target/apple-headers"
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)

if command -v rustup >/dev/null 2>&1; then
  CARGO=(rustup run stable cargo)
  rustup target add "${TARGETS[@]}" >/dev/null
else
  CARGO=(cargo)
fi

cd "$CORE"
for target in "${TARGETS[@]}"; do
  "${CARGO[@]}" build -p rfb-ffi --release --target "$target"
done

rm -rf target/apple-bindings
"${CARGO[@]}" run -p rfb-ffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/librfb_ffi.dylib \
  --language swift \
  --out-dir target/apple-bindings

rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp target/apple-bindings/rfb_ffiFFI.h "$HEADERS/"
cp target/apple-bindings/rfb_ffiFFI.modulemap "$HEADERS/module.modulemap"

lipo -create \
  target/aarch64-apple-ios-sim/release/librfb_ffi.a \
  target/x86_64-apple-ios/release/librfb_ffi.a \
  -output target/apple-librfb_ffi-simulator.a

rm -rf "$OUT/OpenScreensCore.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-darwin/release/librfb_ffi.a -headers "$HEADERS" \
  -library target/aarch64-apple-ios/release/librfb_ffi.a -headers "$HEADERS" \
  -library target/apple-librfb_ffi-simulator.a -headers "$HEADERS" \
  -output "$OUT/OpenScreensCore.xcframework"

mkdir -p "$OUT/Sources/OpenScreensCore"
cp target/apple-bindings/rfb_ffi.swift "$OUT/Sources/OpenScreensCore/rfb_ffi.swift"

echo "Apple core built at $OUT"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/vendor/scrctl/core"
test -f "$CORE/Cargo.toml" || { echo "Run git submodule update --init" >&2; exit 1; }
OUT="$ROOT/apps/apple/OpenScreensCore"
HEADERS="$CORE/target/apple-headers"
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)

if command -v rustup >/dev/null 2>&1; then
  TOOLCHAIN_BIN="$(dirname "$(rustup which rustc)")"
  CARGO=(env "PATH=$TOOLCHAIN_BIN:$PATH" cargo)
  installed="$(rustup target list --installed)"
  for target in "${TARGETS[@]}"; do
    if ! grep -Fxq "$target" <<< "$installed"; then
      rustup target add "$target"
    fi
  done
else
  CARGO=(cargo)
fi

# Native dependencies compile C and assembly alongside Rust. Pass the
# deployment version to their compiler as well as to rustc.
export MACOSX_DEPLOYMENT_TARGET=15.0
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export CFLAGS_aarch64_apple_darwin="${CFLAGS_aarch64_apple_darwin:-} -mmacosx-version-min=15.0"
export CFLAGS_aarch64_apple_ios="${CFLAGS_aarch64_apple_ios:-} -miphoneos-version-min=18.0"
export CFLAGS_aarch64_apple_ios_sim="${CFLAGS_aarch64_apple_ios_sim:-} -mios-simulator-version-min=18.0"
export CFLAGS_x86_64_apple_ios="${CFLAGS_x86_64_apple_ios:-} -mios-simulator-version-min=18.0"

cd "$CORE"
for target in "${TARGETS[@]}"; do
  "${CARGO[@]}" build --locked -p rfb-ffi --release --target "$target"
done

rm -rf target/apple-bindings
"${CARGO[@]}" run --locked -p rfb-ffi-bindgen -- generate \
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

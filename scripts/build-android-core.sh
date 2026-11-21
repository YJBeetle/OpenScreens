#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/vendor/scrctl/core"
APP="$ROOT/apps/android/app/src/main"
test -f "$CORE/Cargo.toml" || { echo "Run git submodule update --init" >&2; exit 1; }
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

if command -v rustup >/dev/null 2>&1; then
  export PATH="$(dirname "$(rustup which rustc)"):$PATH"
fi

cd "$CORE"
cargo ndk -P 26 -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o "$stage/jniLibs" build --locked -p rfb-ffi --release
cargo run --locked -p rfb-ffi-bindgen -- generate \
  --library "$stage/jniLibs/arm64-v8a/librfb_ffi.so" --language kotlin \
  --out-dir "$stage/bindings" --no-format

for abi in arm64-v8a armeabi-v7a x86_64; do
  test -f "$stage/jniLibs/$abi/librfb_ffi.so"
done
rm -rf "$APP/jniLibs"
mv "$stage/jniLibs" "$APP/jniLibs"
cp "$stage/bindings/uniffi/rfb_ffi/rfb_ffi.kt" "$APP/java/uniffi/rfb_ffi/rfb_ffi.kt"

# OpenScreens

Open-source remote desktop client for macOS, iOS, iPadOS and Android, built on a shared Rust core.

## Status

Implemented:

- RFB 3.3/3.7/3.8 client with VNC password and Apple DH authentication (macOS Screen Sharing)
- Raw, CopyRect, RRE, Hextile, ZRLE, zlib and Tight/JPEG decoding into a BGRA framebuffer
- Client-side cursor rendering on macOS (hover-driven pointer) and Android (Cursor and PointerPos pseudo-encodings); iOS keeps the server-composited cursor
- Per-connection Tight JPEG quality selection (the Android quality menu) and paced framebuffer update requests
- TCP and SSH (`direct-tcpip`) transports; SSH jump hosts with password or private-key auth. Android has an encrypted key manager, macOS selects keys directly from `~/.ssh`, and iOS imports private keys into the Keychain (Settings → SSH Keys)
- Native SwiftUI apps for macOS and iOS/iPadOS with a Metal canvas
- Compose Material 3 app for Android

Not yet implemented: Apple Adaptive DCT, automatic quality adaptation, multi-display selection, file transfer, WireGuard/OpenVPN.

## Layout

```
core/crates/rfb-proto/     sans-I/O RFB messages and Apple DH auth
core/crates/rfb-codec/     rectangle decoders
core/crates/rfb-engine/    handshake, session loop, framebuffer
core/crates/rfb-io/        TCP and SSH transports
core/crates/rfb-ffi/       UniFFI surface
apps/apple/OpenScreensUI/  shared SwiftUI views and Metal canvas
apps/apple/OpenScreensCore/ generated Swift bindings (XCFramework built locally)
apps/apple/OpenScreensClient/ UniFFI session adapter
apps/macos/                macOS app shell
apps/ios/                  iOS/iPadOS app shell
apps/android/              Compose Material 3 app
```

## Build

Core:

```sh
cd core
cargo test
cargo clippy --workspace --all-targets -- -D warnings
```

Apple (requires Xcode, xcodegen and Rust Apple targets). Build the FFI package once, then the apps:

```sh
./scripts/build-apple-core.sh

cd apps/macos
xcodegen generate
xcodebuild -project OpenScreens.xcodeproj -scheme OpenScreens \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

The iOS app builds the same way; signing and installation are handled separately.

For a signed and notarized macOS build (requires a Developer ID identity and a
`notarytool` keychain profile):

```sh
DEVELOPER_ID_IDENTITY="Developer ID Application: ..." ./scripts/notarize-macos.sh <notarytool-profile>
```

Android (after changing the Rust core, rebuild the native libraries):

```sh
cd core
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.2.12479018"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o ../apps/android/app/src/main/jniLibs build -p rfb-ffi --release

cd ../apps/android
./gradlew :app:assembleRelease
```

Release signing reads `apps/android/keystore.properties` when present and falls back to debug signing otherwise. The test keystore is local and not committed.

## License

AGPL-3.0. See [LICENSE-AGPL](LICENSE-AGPL).

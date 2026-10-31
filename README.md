# OpenScreens

Open-source remote desktop client for macOS, iOS, iPadOS and Android, built on a shared Rust core.

## Status

Implemented:

- RFB 3.3/3.7/3.8 client with VNC password and Apple DH authentication (macOS Screen Sharing)
- Raw, CopyRect, RRE, Hextile, ZRLE and zlib decoding into a BGRA framebuffer
- TCP and SSH (`direct-tcpip`) transports
- Native SwiftUI apps for macOS and iOS/iPadOS with a Metal canvas
- Compose Material 3 app for Android

Not yet implemented: Tight/JPEG and Apple Adaptive DCT, adaptive quality scaling, WireGuard/OpenVPN, file transfer.

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

Android:

```sh
cd apps/android
./gradlew :app:assembleRelease
```

Release signing reads `apps/android/keystore.properties` when present and falls back to debug signing otherwise. The test keystore is local and not committed.

## License

AGPL-3.0. See [LICENSE-AGPL](LICENSE-AGPL).

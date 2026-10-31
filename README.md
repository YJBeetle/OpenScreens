# OpenScreens

Open-source remote desktop client for macOS, iOS, iPadOS and Android, built on a shared Rust core.

## Status

Implemented:

- RFB 3.3/3.7/3.8 client with VNC password and Apple DH authentication (macOS Screen Sharing)
- Raw, CopyRect, RRE, Hextile, ZRLE, zlib and Tight/JPEG decoding into a BGRA framebuffer
- Client-side cursor rendering on macOS (hover-driven pointer) and Android (Cursor and PointerPos pseudo-encodings); iOS keeps the server-composited cursor
- Per-connection Tight JPEG quality selection (the Android quality menu), paced update requests, and automatic quality adaptation under slow or congested links
- The Android client requests only the visible framebuffer region and samples it at the on-screen pixel density, so 6K Retina hosts stay sharp when zoomed and within the app heap; Apple clients sample wide framebuffers to a 2560-pixel target to keep texture and memory use bounded
- TCP and SSH (`direct-tcpip`) transports; SSH jump hosts with password or private-key auth. Android has an encrypted key manager, macOS selects keys directly from `~/.ssh`, and iOS imports private keys into the Keychain (Settings → SSH Keys)
- Native SwiftUI apps for macOS and iOS/iPadOS with a Metal canvas
- Compose Material 3 app for Android

Not yet implemented: Apple Adaptive DCT, multi-display selection, file transfer, WireGuard/OpenVPN.

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

## Updates

Android and macOS check GitHub Releases and let you choose a channel in Settings:

- **Release** — stable `vX.Y.Z` releases only
- **Pre-release** — the newest release including betas (the rolling `snapshot` tag is excluded)
- **Snapshot** — the rolling development pre-release tagged `snapshot`

The `Snapshot` workflow (manual dispatch) builds and publishes:

- `OpenScreens-snapshot-android.apk` — signed with the release key from the `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` secrets
- `OpenScreens-snapshot-macos.zip` — unsigned until notarization credentials are configured

Stable releases must attach an Android `.apk` and a macOS `.dmg` or `.zip` with names containing `android` / `macos`. On Android the update card's primary action opens the GitHub release page; the in-app download that hands the APK to the system installer remains available. iOS is distributed through the App Store and does not use this updater.

Release signing uses repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. The `Build` environment holds the macOS Apple ID notarization secrets (`NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD`), the variables `SIGNING_IDENTITY` / `SIGNING_TEAM_ID`, and — once exported — the `SIGNING_CERTIFICATE_P12_BASE64` / `SIGNING_CERTIFICATE_PASSWORD` secrets. Without the certificate secrets the snapshot macOS build is packaged unsigned.

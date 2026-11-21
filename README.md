# OpenScreens

Open-source remote desktop client for macOS, iOS and iPadOS, built on a shared Rust core.

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
- Apple Screen Sharing 3.889 sessions: AES-encrypted pointer/keyboard input, Apple clipboard messages, display-list pseudo-encodings, display switching, and drag-and-drop file upload
- File transfer: Android upload picker and remote-path download with progress; drag-and-drop upload on the Apple apps
- Userspace WireGuard transport (`rfb-tunnel` + `TunnelDialer`) with Android wg-quick config import; OpenVPN and WireGuard runtime acceptance are pending
- Apple Adaptive DCT (1011): type-0/type-2 decoding validated against live 3.889 streams and negotiated first; type-1 coefficient refinement and explicit/sequential cache reads tested against synthetic Screens 5.9 vectors. Unsupported copy references fall back to standard encodings with a full refresh

Planned:

- [ ] macOS Screen Sharing guest requests. Offer a request option in the connection authentication prompt without requiring a remote Mac username or password. The remote Mac must allow screen control requests, and its user must approve before the session starts. Verify approval, denial, cancellation, and the message shown when guest requests are disabled on a real Mac.

## Layout

```
vendor/scrctl/core/crates/rfb-proto/     sans-I/O RFB messages and Apple DH auth
vendor/scrctl/core/crates/rfb-codec/     rectangle decoders
vendor/scrctl/core/crates/rfb-tunnel/    userspace WireGuard tunnel
vendor/scrctl/core/crates/rfb-engine/    handshake, session loop, framebuffer
vendor/scrctl/core/crates/rfb-io/        TCP and SSH transports
vendor/scrctl/core/crates/rfb-ffi/       UniFFI surface
apps/apple/OpenScreensUI/  shared SwiftUI views and Metal canvas
apps/apple/OpenScreensCore/ generated Swift bindings (XCFramework built locally)
apps/apple/OpenScreensClient/ UniFFI session adapter
apps/macos/                macOS app shell
apps/ios/                  iOS/iPadOS app shell
```

## Build

Core:

```sh
git submodule update --init
cd vendor/scrctl/core
cargo test
cargo clippy --workspace --all-targets -- -D warnings
```

Apple (requires Xcode, xcodegen and Rust Apple targets). Build the FFI package once, then the apps:

```sh
git submodule update --init
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

See [scrctl-gui-android](https://github.com/scrctl/scrctl-gui-android) for the Android client.

## License

AGPL-3.0. See [LICENSE-AGPL](LICENSE-AGPL).

## Updates

macOS checks GitHub Releases and let you choose a channel in Settings:

- **Release** — stable `vX.Y.Z` releases only
- **Pre-release** — the newest release including betas (the rolling `snapshot` tag is excluded)
- **Snapshot** — the rolling development pre-release tagged `snapshot`

The `Snapshot` workflow (manual dispatch) builds and publishes:

- `OpenScreens-snapshot-macos.zip` — unsigned until notarization credentials are configured

Stable releases attach a macOS archive. iOS is distributed through the App Store.

The `Build` environment holds the macOS Apple ID notarization secrets (`NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD`), the variables `SIGNING_IDENTITY` / `SIGNING_TEAM_ID`, and the `APPLE_CERTIFICATE_P12_BASE64` / `APPLE_CERTIFICATE_PASSWORD` secrets. Without the certificate secrets the snapshot macOS build is packaged unsigned.

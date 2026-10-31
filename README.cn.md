# OpenScreens

开源远程桌面客户端，目标平台 macOS、iOS、iPadOS 与 Android，协议核心由 Rust 共享。

## 状态

已实现：

- RFB 3.3/3.7/3.8 客户端，支持 VNC 密码认证与 Apple DH 认证（macOS 屏幕共享）
- Raw、CopyRect、RRE、Hextile、ZRLE、zlib、Tight/JPEG 解码到 BGRA 帧缓冲
- macOS（悬停即移动指针）与 Android 客户端本地光标渲染（Cursor 与 PointerPos 伪编码）；iOS 仍使用服务端合成光标
- 按连接选择 Tight JPEG 画质（Android 画质菜单），并对帧更新请求限速
- Android 只请求当前可见的帧缓冲区域，并按屏幕像素密度采样；6K Retina 主机放大后依旧清晰，位图内存受控。Apple 端把宽帧缓冲采样到 2560 像素目标宽，纹理与内存占用受控
- TCP 与 SSH（direct-tcpip）传输；跳板机支持密码或私钥认证。Android 有加密的密钥管理，macOS 直接选用 `~/.ssh` 下的私钥，iOS 可导入私钥到钥匙串（设置 → SSH Keys）
- macOS 与 iOS/iPadOS 的 SwiftUI 应用，Metal 画布
- Android 的 Compose Material 3 应用

尚未实现：Apple Adaptive DCT、按带宽自动调节画质、多显示器选择、文件传输、WireGuard/OpenVPN。

## 目录

```
core/crates/rfb-proto/     sans-I/O RFB 消息与 Apple DH 认证
core/crates/rfb-codec/     矩形解码器
core/crates/rfb-engine/    握手、会话循环、帧缓冲
core/crates/rfb-io/        TCP 与 SSH 传输
core/crates/rfb-ffi/       UniFFI 接口层
apps/apple/OpenScreensUI/  共享 SwiftUI 视图与 Metal 画布
apps/apple/OpenScreensCore/ 生成的 Swift 绑定（XCFramework 本地构建）
apps/apple/OpenScreensClient/ UniFFI 会话适配层
apps/macos/                macOS 应用壳
apps/ios/                  iOS/iPadOS 应用壳
apps/android/              Compose Material 3 应用
```

## 构建

核心：

```sh
cd core
cargo test
cargo clippy --workspace --all-targets -- -D warnings
```

Apple（需要 Xcode、xcodegen 与 Rust Apple targets）。先构建一次 FFI 包，再构建应用：

```sh
./scripts/build-apple-core.sh

cd apps/macos
xcodegen generate
xcodebuild -project OpenScreens.xcodeproj -scheme OpenScreens \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

iOS 使用同样的工程结构；签名与装机单独处理。

macOS 的签名与公证（需要 Developer ID 证书和 `notarytool` 凭据）：

```sh
DEVELOPER_ID_IDENTITY="Developer ID Application: ..." ./scripts/notarize-macos.sh <notarytool-profile>
```

Android（改动 Rust core 后需要重编原生库）：

```sh
cd core
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.2.12479018"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o ../apps/android/app/src/main/jniLibs build -p rfb-ffi --release

cd ../apps/android
./gradlew :app:assembleRelease
```

Release 签名在存在 `apps/android/keystore.properties` 时使用本地测试密钥，否则回退到 debug 签名；测试密钥不入库。

## 许可证

AGPL-3.0，见 [LICENSE-AGPL](LICENSE-AGPL)。

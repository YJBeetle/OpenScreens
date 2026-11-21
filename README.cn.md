# OpenScreens

开源远程桌面客户端，目标平台 macOS、iOS 与 iPadOS，协议核心由 Rust 共享。

## 状态

已实现：

- RFB 3.3/3.7/3.8 客户端，支持 VNC 密码认证与 Apple DH 认证（macOS 屏幕共享）
- Raw、CopyRect、RRE、Hextile、ZRLE、zlib、Tight/JPEG 解码到 BGRA 帧缓冲
- macOS（悬停即移动指针）与 Android 客户端本地光标渲染（Cursor 与 PointerPos 伪编码）；iOS 仍使用服务端合成光标
- 按连接选择 Tight JPEG 画质（Android 画质菜单），对帧更新请求限速，并在链路变慢时自动下调画质
- TCP 与 SSH（direct-tcpip）传输；跳板机支持密码或私钥认证。Android 有加密的密钥管理，macOS 直接选用 `~/.ssh` 下的私钥，iOS 可导入私钥到钥匙串（设置 → SSH Keys）
- macOS 与 iOS/iPadOS 的 SwiftUI 应用，Metal 画布
- Apple 3.889 会话：加密指针/键盘、Apple 剪贴板消息、显示列表伪编码、显示器切换与拖放上传
- 文件传输：Android 上传选择器与按远端路径下载（带进度）；Apple 端拖放上传
- 用户态 WireGuard 传输（`rfb-tunnel` + `TunnelDialer`）与 Android wg-quick 配置导入；OpenVPN 与 WireGuard 运行时验收待做
- Apple Adaptive DCT（1011）：type-0/type-2 解码已在真实 3.889 流上验证并默认优先协商；type-1 系数细化和显式／顺序缓存读取已对照 Screens 5.9 的合成输入验证，遇到未支持的复制引用会退回标准编码并请求全量刷新

待办：

- [ ] macOS 屏幕共享「通过请求许可」。在连接认证界面提供访客请求入口，无需输入远端 Mac 的用户名或密码。远端 Mac 须启用「任何人都可以请求取得屏幕控制权限」，并由现场用户批准后进入会话。在真实 Mac 上验证批准、拒绝、主动取消，以及远端未启用访客请求时的提示。

## 目录

```
vendor/scrctl/core/crates/rfb-proto/     sans-I/O RFB 消息与 Apple DH 认证
vendor/scrctl/core/crates/rfb-codec/     矩形解码器
vendor/scrctl/core/crates/rfb-tunnel/    用户态 WireGuard 隧道
vendor/scrctl/core/crates/rfb-engine/    握手、会话循环、帧缓冲
vendor/scrctl/core/crates/rfb-io/        TCP 与 SSH 传输
vendor/scrctl/core/crates/rfb-ffi/       UniFFI 接口层
apps/apple/OpenScreensUI/  共享 SwiftUI 视图与 Metal 画布
apps/apple/OpenScreensCore/ 生成的 Swift 绑定（XCFramework 本地构建）
apps/apple/OpenScreensClient/ UniFFI 会话适配层
apps/macos/                macOS 应用壳
apps/ios/                  iOS/iPadOS 应用壳
```

## 构建

核心：

```sh
git submodule update --init
cd vendor/scrctl/core
cargo test
cargo clippy --workspace --all-targets -- -D warnings
```

Apple（需要 Xcode、xcodegen 与 Rust Apple targets）。先构建一次 FFI 包，再构建应用：

```sh
git submodule update --init
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

Android 客户端见 [scrctl-gui-android](https://github.com/scrctl/scrctl-gui-android)。

## 许可证

AGPL-3.0，见 [LICENSE-AGPL](LICENSE-AGPL)。

## 更新

macOS 从 GitHub Releases 检查正式版、预发行版和开发快照。iOS 通过 App Store 分发。

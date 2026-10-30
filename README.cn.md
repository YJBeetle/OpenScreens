# OpenScreens

开源远程桌面客户端，目标平台 iOS、iPadOS 与 Android，协议核心由 Rust 共享。

项目处于早期开发阶段，目前还没有可用的应用。

## 范围

- RFB（VNC）客户端，支持 macOS 屏幕共享与标准 VNC 服务端
- Rust 协议核心 + 各平台原生前端
- 首版直连 TCP 与 SSH，后续通过 VPN 做远程接入

## 目录

```
core/crates/rfb-proto/   sans-I/O RFB 协议基础类型
```

## 开发

```sh
cd core
cargo test
cargo clippy --workspace --all-targets -- -D warnings
```

## 许可证

Apache-2.0，见 [LICENSE-APACHE](LICENSE-APACHE)。

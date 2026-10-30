# OpenScreens

Open-source remote desktop client for iOS, iPadOS and Android, built on a shared Rust core.

The project is in early development; there are no usable apps yet.

## Scope

- RFB (VNC) client for macOS Screen Sharing and standard VNC servers
- Shared Rust protocol core with native frontends
- Direct TCP and SSH transports first, VPN-based remote access later

## Layout

```
core/crates/rfb-proto/   sans-I/O RFB protocol primitives
```

## Development

```sh
cd core
cargo test
cargo clippy --workspace --all-targets -- -D warnings
```

## License

Apache-2.0. See [LICENSE-APACHE](LICENSE-APACHE).

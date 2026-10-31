//! `.ovpn` client profile parsing.
//!
//! The parser accepts the subset needed by a userspace client: a single
//! `remote`, `dev tun`, UDP or TCP, PKI files (path or inline), optional
//! `tls-auth`/`tls-crypt`, `auth`, `cipher`/`data-ciphers` and
//! `remote-cert-tls`. OS-level directives such as `route`, `dhcp-option`,
//! `up`/`down` and `dh` are parsed but never executed; anything that would
//! silently change the tunnel semantics is rejected with an explicit
//! [`ConfigError::Unsupported`].
//!
//! Inline material and private keys are redacted from `Debug` output.

use std::collections::HashMap;
use std::fmt;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use crate::cipher::{AuthDigest, Cipher};
use crate::error::ConfigError;

/// Outer transport of the OpenVPN session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Proto {
    /// UDP datagrams (raw OpenVPN packets).
    Udp,
    /// TCP with a two-byte big-endian length prefix per packet.
    Tcp,
}

impl Proto {
    /// The token OpenVPN uses in its OCC options string.
    pub fn options_token(self) -> &'static str {
        match self {
            Self::Udp => "UDPv4",
            Self::Tcp => "TCPv4_CLIENT",
        }
    }

    /// Short name for status displays.
    pub fn name(self) -> &'static str {
        match self {
            Self::Udp => "udp",
            Self::Tcp => "tcp",
        }
    }
}

/// One `remote host [port] [proto]` entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Remote {
    /// Host name or IPv4 literal.
    pub host: String,
    /// Destination port.
    pub port: u16,
    /// Transport for this remote.
    pub proto: Proto,
}

impl Remote {
    /// `host:port` for status displays.
    pub fn endpoint(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

/// Reads or embeds one PEM/static-key material.
#[derive(Clone)]
pub enum Material {
    /// Material written inside `<ca>...</ca>` and friends.
    Inline(String),
    /// A path resolved against the directory of the profile, when known.
    Path(PathBuf),
}

impl Material {
    /// Returns the inline text, if any.
    pub fn inline(&self) -> Option<&str> {
        match self {
            Self::Inline(text) => Some(text),
            Self::Path(_) => None,
        }
    }

    /// Returns the path, if any.
    pub fn path(&self) -> Option<&Path> {
        match self {
            Self::Inline(_) => None,
            Self::Path(path) => Some(path),
        }
    }

    /// Loads the material. Relative paths use `base` when it is supplied.
    pub fn load(&self, base: Option<&Path>) -> Result<Vec<u8>, ConfigError> {
        match self {
            Self::Inline(text) => Ok(text.as_bytes().to_vec()),
            Self::Path(path) => {
                let resolved = match (base, path.is_absolute()) {
                    (Some(base), false) => base.join(path),
                    _ => path.clone(),
                };
                std::fs::read(&resolved).map_err(|source| ConfigError::Io {
                    path: resolved.display().to_string(),
                    source,
                })
            }
        }
    }
}

impl fmt::Debug for Material {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Inline(text) => write!(f, "Inline(<{} bytes redacted>)", text.len()),
            Self::Path(path) => f.debug_tuple("Path").field(path).finish(),
        }
    }
}

/// Control-channel wrapping mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TlsWrapMode {
    /// `--tls-auth`: HMAC-SHA1 only.
    Auth,
    /// `--tls-crypt`: AES-256-CTR + HMAC-SHA-256.
    Crypt,
}

/// A parsed `tls-auth`/`tls-crypt` option.
#[derive(Debug, Clone)]
pub struct TlsWrapConfig {
    /// Wrapping mode.
    pub mode: TlsWrapMode,
    /// Static key block or path.
    pub material: Material,
    /// `tls-auth` key direction (0 or 1); `tls-crypt` ignores it.
    pub direction: Option<u8>,
}

/// Which peer certificate usage the client requires.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteCertTls {
    /// `remote-cert-tls server`.
    Server,
}

/// A parsed client profile.
#[derive(Debug, Clone)]
pub struct OvpnConfig {
    /// Remotes in order; only the first is used by this version.
    pub remotes: Vec<Remote>,
    /// Trusted CA bundle.
    pub ca: Material,
    /// Client certificate chain.
    pub cert: Material,
    /// Client private key.
    pub key: Material,
    /// Optional control-channel wrapping.
    pub tls_wrap: Option<TlsWrapConfig>,
    /// Selected data-channel cipher.
    pub cipher: Cipher,
    /// Data-channel digest (used by the options string and CBC profiles).
    pub auth: AuthDigest,
    /// `remote-cert-tls` requirement, when configured.
    pub remote_cert_tls: Option<RemoteCertTls>,
    /// Inner tunnel MTU.
    pub tun_mtu: u16,
    /// Global `key-direction`, if any.
    pub key_direction: Option<u8>,
    /// Non-fatal parser findings suitable for the UI.
    pub warnings: Vec<String>,
    /// Directory used to resolve relative material paths.
    pub base_dir: Option<PathBuf>,
}

impl OvpnConfig {
    /// Parses a profile with relative paths resolved against the current
    /// directory.
    pub fn parse(text: &str) -> Result<Self, ConfigError> {
        parse_profile(text, None)
    }

    /// Parses a profile and remembers its directory for relative files.
    pub fn parse_with_base(text: &str, base: Option<PathBuf>) -> Result<Self, ConfigError> {
        parse_profile(text, base)
    }

    /// Reads and parses a profile from disk.
    pub fn parse_file(path: &Path) -> Result<Self, ConfigError> {
        let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Io {
            path: path.display().to_string(),
            source,
        })?;
        parse_profile(&text, path.parent().map(Path::to_path_buf))
    }

    /// The remote used by this version.
    pub fn remote(&self) -> &Remote {
        &self.remotes[0]
    }

    /// Loads the CA, certificate, key and optional static key.
    pub fn load_material(&self) -> Result<LoadedMaterial, ConfigError> {
        let tls_wrap = match &self.tls_wrap {
            Some(config) => {
                let bytes = config.material.load(self.base_dir.as_deref())?;
                let text = String::from_utf8(bytes).map_err(|_| ConfigError::Invalid {
                    directive: "tls-crypt",
                    detail: "the static key is not UTF-8 text".to_string(),
                })?;
                Some(LoadedTlsWrap {
                    mode: config.mode,
                    direction: config.direction,
                    key_text: text,
                })
            }
            None => None,
        };
        Ok(LoadedMaterial {
            ca_pem: self.ca.load(self.base_dir.as_deref())?,
            cert_pem: self.cert.load(self.base_dir.as_deref())?,
            key_pem: self.key.load(self.base_dir.as_deref())?,
            tls_wrap,
            base_dir: self.base_dir.clone(),
        })
    }

    /// The OCC options string sent in key-method 2.
    pub fn options_string(&self) -> String {
        format!(
            "V4,dev-type tun,link-mtu {},tun-mtu {},proto {},cipher {},auth {},keysize {},key-method 2,tls-client",
            u32::from(self.tun_mtu) + 21,
            self.tun_mtu,
            self.remote().proto.options_token(),
            self.cipher.name(),
            self.auth.name(),
            self.cipher.key_bits(),
        )
    }

    /// The `IV_*` peer-info block sent in key-method 2.
    pub fn peer_info(&self) -> String {
        format!(
            "IV_VER=2.6.0\nIV_PLAT=rust\nIV_TCPNL=1\nIV_MTU={}\nIV_NCP=2\nIV_CIPHERS={}\nIV_PROTO=2\n",
            self.tun_mtu,
            self.cipher.name(),
        )
    }
}

/// Material loaded from a profile.
pub struct LoadedMaterial {
    /// CA bundle in PEM form.
    pub ca_pem: Vec<u8>,
    /// Client certificate chain in PEM form.
    pub cert_pem: Vec<u8>,
    /// Client private key in PEM form.
    pub key_pem: Vec<u8>,
    /// Static key text.
    pub tls_wrap: Option<LoadedTlsWrap>,
    /// Directory used for later path resolution.
    pub base_dir: Option<PathBuf>,
}

/// A loaded static-key option.
#[derive(Clone)]
pub struct LoadedTlsWrap {
    /// Mode.
    pub mode: TlsWrapMode,
    /// Direction for tls-auth.
    pub direction: Option<u8>,
    /// PEM-armoured or bare hex static key.
    pub key_text: String,
}

impl fmt::Debug for LoadedTlsWrap {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoadedTlsWrap")
            .field("mode", &self.mode)
            .field("direction", &self.direction)
            .field("key_text", &"<redacted>")
            .finish()
    }
}

#[derive(Default)]
struct RemoteDraft {
    host: String,
    port: u16,
    proto: Option<Proto>,
}

#[derive(Default)]
struct Builder {
    remotes: Vec<RemoteDraft>,
    proto: Option<Proto>,
    client: bool,
    pull: bool,
    tls_client: bool,
    ca_path: Option<PathBuf>,
    cert_path: Option<PathBuf>,
    key_path: Option<PathBuf>,
    inline: HashMap<String, String>,
    tls_auth_path: Option<PathBuf>,
    tls_auth_declared: bool,
    tls_auth_direction: Option<u8>,
    tls_crypt_path: Option<PathBuf>,
    tls_crypt_declared: bool,
    key_direction: Option<u8>,
    data_ciphers: Vec<String>,
    fallback_cipher: Option<String>,
    cipher: Option<String>,
    auth: AuthDigest,
    remote_cert_tls: Option<RemoteCertTls>,
    tun_mtu: u16,
    warnings: Vec<String>,
}

impl Builder {
    fn new() -> Self {
        Self {
            auth: AuthDigest::Sha1,
            tun_mtu: 1500,
            ..Self::default()
        }
    }

    fn warn(&mut self, message: impl Into<String>) {
        let message = message.into();
        if !self.warnings.contains(&message) {
            self.warnings.push(message);
        }
    }
}

fn set_path(
    slot: &mut Option<PathBuf>,
    directive: &'static str,
    value: &str,
    warnings: &mut Vec<String>,
) {
    if value.is_empty() || value == "[inline]" {
        return;
    }
    let path = PathBuf::from(value);
    if slot.as_ref() == Some(&path) {
        return;
    }
    if slot.is_some() {
        let message = format!("duplicate {directive}; using the last value");
        if !warnings.contains(&message) {
            warnings.push(message);
        }
    }
    *slot = Some(path);
}

fn parse_profile(text: &str, base: Option<PathBuf>) -> Result<OvpnConfig, ConfigError> {
    let mut builder = Builder::new();
    let mut inline: Option<(String, String)> = None;

    for (index, raw) in text.lines().enumerate() {
        let line_number = index + 1;
        let raw = raw.trim_end_matches('\r');
        let raw = if index == 0 {
            raw.trim_start_matches('\u{feff}')
        } else {
            raw
        };

        if let Some((tag, buffer)) = inline.as_mut() {
            let trimmed = raw.trim();
            if trimmed.eq_ignore_ascii_case(&format!("</{tag}>")) {
                let (tag, body) = inline.take().expect("inline state exists");
                builder.inline.insert(tag, body);
            } else {
                buffer.push_str(raw);
                buffer.push('\n');
            }
            continue;
        }

        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';') {
            continue;
        }

        if let Some(rest) = trimmed.strip_prefix('<') {
            let Some((tag, trailing)) = rest.split_once('>') else {
                return Err(ConfigError::Syntax {
                    line: line_number,
                    detail: "unterminated inline block tag".to_string(),
                });
            };
            if !trailing.trim().is_empty() {
                return Err(ConfigError::Syntax {
                    line: line_number,
                    detail: "unexpected text after an inline block tag".to_string(),
                });
            }
            let tag = tag.trim().to_ascii_lowercase();
            if tag.is_empty() || tag.starts_with('/') {
                return Err(ConfigError::Syntax {
                    line: line_number,
                    detail: "unexpected closing inline block".to_string(),
                });
            }
            check_inline_tag(&tag)?;
            inline = Some((tag, String::new()));
            continue;
        }

        let words = split_words(trimmed).map_err(|detail| ConfigError::Syntax {
            line: line_number,
            detail,
        })?;
        let Some(directive) = words.first() else {
            continue;
        };
        let directive = directive.to_ascii_lowercase();
        let value = words[1..].join(" ");
        apply_directive(&mut builder, &directive, &words[1..], &value)?;
    }

    if inline.is_some() {
        return Err(ConfigError::Syntax {
            line: text.lines().count(),
            detail: "unterminated inline block".to_string(),
        });
    }

    finish(builder, base)
}

fn check_inline_tag(tag: &str) -> Result<(), ConfigError> {
    match tag {
        "ca" | "cert" | "key" | "tls-auth" | "tls-crypt" | "dh" | "extra-certs" | "connection"
        | "secret" | "pkcs12" | "auth-user-pass" | "http-proxy" | "socks-proxy" => Ok(()),
        other => Err(ConfigError::Unsupported(format!(
            "inline block <{other}> is not recognised"
        ))),
    }
}

fn apply_directive(
    builder: &mut Builder,
    directive: &str,
    words: &[String],
    value: &str,
) -> Result<(), ConfigError> {
    match directive {
        "client" => builder.client = true,
        "pull" => builder.pull = true,
        "tls-client" => builder.tls_client = true,
        "dev" => {
            let dev = value.to_ascii_lowercase();
            if dev.starts_with("tun") {
                // fine
            } else if dev.starts_with("tap") {
                return Err(ConfigError::Unsupported(
                    "dev tap is not supported; only tun".to_string(),
                ));
            } else {
                return Err(ConfigError::Invalid {
                    directive: "dev",
                    detail: "expected tun".to_string(),
                });
            }
        }
        "dev-type" => {
            if !value.eq_ignore_ascii_case("tun") {
                return Err(ConfigError::Unsupported(
                    "only dev-type tun is supported".to_string(),
                ));
            }
        }
        "proto" => {
            let proto = parse_proto(value)?;
            builder.proto = Some(proto);
        }
        "remote" => {
            let Some(host) = words.first() else {
                return Err(ConfigError::Invalid {
                    directive: "remote",
                    detail: "expected host [port] [proto]".to_string(),
                });
            };
            if host.starts_with('[') || IpAddr::from_str(host).is_ok_and(|ip| ip.is_ipv6()) {
                return Err(ConfigError::Unsupported(
                    "IPv6 remotes are not supported".to_string(),
                ));
            }
            let port = match words.get(1) {
                Some(port) => port.parse::<u16>().map_err(|_| ConfigError::Invalid {
                    directive: "remote",
                    detail: "the port is not a number between 1 and 65535".to_string(),
                })?,
                None => 1194,
            };
            if port == 0 {
                return Err(ConfigError::Invalid {
                    directive: "remote",
                    detail: "the port must not be zero".to_string(),
                });
            }
            let proto = match words.get(2) {
                Some(proto) => Some(parse_proto(proto)?),
                None => None,
            };
            if builder.remotes.iter().any(|remote| {
                remote.host == *host && remote.port == port && remote.proto == proto
            }) {
                builder.warn("duplicate remote ignored".to_string());
            } else {
                if !builder.remotes.is_empty() {
                    builder.warn("multiple remotes parsed; only the first is used".to_string());
                }
                builder.remotes.push(RemoteDraft {
                    host: host.clone(),
                    port,
                    proto,
                });
            }
        }
        "remote-random" => builder.warn("remote-random is ignored; the first remote is used"),
        "ca" => set_path(&mut builder.ca_path, "ca", value, &mut builder.warnings),
        "cert" => set_path(&mut builder.cert_path, "cert", value, &mut builder.warnings),
        "key" => set_path(&mut builder.key_path, "key", value, &mut builder.warnings),
        "tls-auth" => {
            builder.tls_auth_declared = true;
            if !value.is_empty() && value != "[inline]" {
                set_path(
                    &mut builder.tls_auth_path,
                    "tls-auth",
                    words[0].as_str(),
                    &mut builder.warnings,
                );
            }
            if let Some(direction) = words.get(1) {
                builder.tls_auth_direction = Some(parse_direction(direction, "tls-auth")?);
            }
        }
        "tls-crypt" => {
            builder.tls_crypt_declared = true;
            if !value.is_empty() && value != "[inline]" {
                set_path(
                    &mut builder.tls_crypt_path,
                    "tls-crypt",
                    words[0].as_str(),
                    &mut builder.warnings,
                );
            }
        }
        "tls-crypt-v2" | "tls-crypt-v2-verify" => {
            return Err(ConfigError::Unsupported(
                "tls-crypt-v2 is not supported; use tls-crypt or tls-auth".to_string(),
            ));
        }
        "key-direction" => {
            let direction = parse_direction(value, "key-direction")?;
            builder.key_direction = Some(direction);
        }
        "auth" => {
            builder.auth = AuthDigest::parse(value).ok_or_else(|| ConfigError::Invalid {
                directive: "auth",
                detail: "supported digests are SHA1, SHA256 and SHA512".to_string(),
            })?;
        }
        "cipher" => builder.cipher = Some(value.to_string()),
        "data-ciphers" => {
            builder.data_ciphers = value
                .split(':')
                .map(|item| item.trim().trim_start_matches('?'))
                .filter(|item| !item.is_empty())
                .map(ToOwned::to_owned)
                .collect();
        }
        "data-ciphers-fallback" => builder.fallback_cipher = Some(value.to_string()),
        "remote-cert-tls" => match value.to_ascii_lowercase().as_str() {
            "server" => builder.remote_cert_tls = Some(RemoteCertTls::Server),
            "client" => {
                return Err(ConfigError::Unsupported(
                    "remote-cert-tls client is not a client profile".to_string(),
                ));
            }
            _ => {
                return Err(ConfigError::Invalid {
                    directive: "remote-cert-tls",
                    detail: "expected server".to_string(),
                });
            }
        },
        "tun-mtu" => {
            let mtu = value.parse::<u16>().map_err(|_| ConfigError::Invalid {
                directive: "tun-mtu",
                detail: "expected an integer".to_string(),
            })?;
            let clamped = mtu.clamp(1280, 1500);
            if clamped != mtu {
                builder.warn(format!(
                    "tun-mtu {mtu} is outside 1280-1500; using {clamped}"
                ));
            }
            builder.tun_mtu = clamped;
        }
        "fragment" => {
            return Err(ConfigError::Unsupported(
                "fragment is not supported".to_string(),
            ));
        }
        "link-mtu" | "tun-mtu-extra" | "mssfix" => {}
        "comp-lzo" | "compress" => {
            return Err(ConfigError::Unsupported(
                "compression is not supported; disable comp-lzo/compress on the server"
                    .to_string(),
            ));
        }
        "allow-compression" => {
            if value.eq_ignore_ascii_case("yes") || value.eq_ignore_ascii_case("asym") {
                return Err(ConfigError::Unsupported(
                    "compression is not supported".to_string(),
                ));
            }
        }
        "auth-user-pass" | "askpass" | "pkcs12" | "secret" => {
            return Err(ConfigError::Unsupported(format!(
                "{directive} authentication is not supported; a PKI client certificate and key are required"
            )));
        }
        "http-proxy" | "socks-proxy" | "http-proxy-option" | "http-proxy-user-pass" => {
            return Err(ConfigError::Unsupported(
                "proxy options are not supported".to_string(),
            ));
        }
        "verify-x509-name" => builder.warn(
            "verify-x509-name is ignored; the server certificate chain is verified but its name is not",
        ),
        "ns-cert-type" => builder.warn("ns-cert-type is ignored"),
        "tls-version-min" | "tls-version-max" | "tls-cipher" | "tls-ciphersuites"
        | "tls-groups" | "tls-cert-profile" => {
            builder.warn(format!("{directive} is ignored; rustls chooses TLS parameters"))
        }
        "crl-verify" => builder.warn("crl-verify is ignored; revocation checking is not supported"),
        "verb" => {
            if value.parse::<u8>().is_err() {
                builder.warn("verb is not a number and was ignored");
            }
        }
        "route-nopull" | "pull-filter" => {
            return Err(ConfigError::Unsupported(format!(
                "{directive} would change pushed routing, which is not implemented"
            )));
        }
        "route" | "route-ipv6" | "route-gateway" | "redirect-gateway" | "route-delay"
        | "route-metric" | "topology" | "ifconfig" | "ifconfig-ipv6" | "dhcp-option"
        | "dhcp-option-ipv6" | "register-dns" | "block-outside-dns" | "dh" => {
            builder.warn(format!(
                "ignored {directive}: OS-level networking directives are never executed"
            ));
        }
        "up" | "down" | "route-up" | "route-pre-down" | "ipchange" | "client-connect"
        | "client-disconnect" | "plugin" | "script-security" | "learn-address" => {
            builder.warn(format!(
                "ignored {directive}: configuration scripts are never executed"
            ));
        }
        "user" | "group" | "chroot" | "daemon" | "log" | "log-append" | "writepid" | "cd"
        | "management" | "management-client" | "management-hold" | "management-signal"
        | "management-forget-disconnect" | "management-up-down" | "management-log-cache"
        | "management-query-passwords" => {
            builder.warn(format!("ignored {directive}: not applicable to an in-process client"));
        }
        "nobind" | "persist-key" | "persist-tun" | "resolv-retry" | "connect-retry"
        | "connect-retry-max" | "connect-timeout" | "hand-window" | "reneg-sec"
        | "explicit-exit-notify" | "ping" | "ping-restart" | "ping-exit" | "inactive"
        | "mute" | "mute-replay-warnings" | "sndbuf" | "rcvbuf" | "fast-io" | "float"
        | "auth-nocache" | "single-session" | "tls-exit" | "setenv" | "setenv-safe"
        | "port" | "lport" | "remote-random-hostname" => {}
        "connection" => {
            return Err(ConfigError::Unsupported(
                "<connection> blocks are not supported; use a single remote".to_string(),
            ));
        }
        other => builder.warn(format!("ignored unknown directive {other}")),
    }
    Ok(())
}

fn parse_proto(value: &str) -> Result<Proto, ConfigError> {
    match value.trim().to_ascii_lowercase().as_str() {
        "udp" | "udp4" | "udp-client" => Ok(Proto::Udp),
        "tcp" | "tcp-client" | "tcp4" | "tcp4-client" => Ok(Proto::Tcp),
        "udp6" | "tcp6" | "tcp6-client" | "tcp-server" => Err(ConfigError::Unsupported(
            "IPv6 and server-side protocols are not supported".to_string(),
        )),
        _ => Err(ConfigError::Invalid {
            directive: "proto",
            detail: "expected udp, udp4, tcp or tcp-client".to_string(),
        }),
    }
}

fn parse_direction(value: &str, directive: &str) -> Result<u8, ConfigError> {
    match value.trim() {
        "0" => Ok(0),
        "1" => Ok(1),
        _ => Err(ConfigError::Invalid {
            directive: if directive == "tls-auth" {
                "tls-auth"
            } else {
                "key-direction"
            },
            detail: "the key direction must be 0 or 1".to_string(),
        }),
    }
}

fn finish(mut builder: Builder, base: Option<PathBuf>) -> Result<OvpnConfig, ConfigError> {
    if builder.remotes.is_empty() {
        return Err(ConfigError::Missing("remote"));
    }
    if !builder.client && !(builder.pull && builder.tls_client) {
        return Err(ConfigError::Missing("client"));
    }

    let inline = std::mem::take(&mut builder.inline);
    let has_inline_auth = inline.contains_key("tls-auth");
    let has_inline_crypt = inline.contains_key("tls-crypt");
    if (builder.tls_auth_declared || has_inline_auth)
        && (builder.tls_crypt_declared || has_inline_crypt)
    {
        return Err(ConfigError::Conflict(
            "tls-auth and tls-crypt cannot be used together".to_string(),
        ));
    }
    if builder.tls_auth_declared && !has_inline_auth && builder.tls_auth_path.is_none() {
        return Err(ConfigError::Missing("tls-auth key"));
    }
    if builder.tls_crypt_declared && !has_inline_crypt && builder.tls_crypt_path.is_none() {
        return Err(ConfigError::Missing("tls-crypt key"));
    }

    let ca = material("ca", inline.get("ca"), builder.ca_path.clone())?;
    let cert = material("cert", inline.get("cert"), builder.cert_path.clone())?;
    let key = material("key", inline.get("key"), builder.key_path.clone())?;

    let tls_wrap = if has_inline_auth {
        let text = inline.get("tls-auth").expect("checked above");
        Some(TlsWrapConfig {
            mode: TlsWrapMode::Auth,
            material: Material::Inline(text.clone()),
            direction: builder.tls_auth_direction.or(builder.key_direction),
        })
    } else if let Some(path) = builder.tls_auth_path.clone() {
        Some(TlsWrapConfig {
            mode: TlsWrapMode::Auth,
            material: Material::Path(path),
            direction: builder.tls_auth_direction.or(builder.key_direction),
        })
    } else if has_inline_crypt {
        let text = inline.get("tls-crypt").expect("checked above");
        Some(TlsWrapConfig {
            mode: TlsWrapMode::Crypt,
            material: Material::Inline(text.clone()),
            direction: None,
        })
    } else {
        builder.tls_crypt_path.clone().map(|path| TlsWrapConfig {
            mode: TlsWrapMode::Crypt,
            material: Material::Path(path),
            direction: None,
        })
    };

    let cipher = choose_cipher(&mut builder)?;
    if builder.remote_cert_tls.is_none() {
        builder.warn(
            "remote-cert-tls server is missing; the chain is still verified but server EKU usage is required",
        );
    }

    for directive in ["dh", "extra-certs"] {
        if inline.contains_key(directive) {
            builder.warn(format!("ignored inline <{directive}> block"));
        }
    }
    for directive in [
        "secret",
        "pkcs12",
        "auth-user-pass",
        "http-proxy",
        "socks-proxy",
    ] {
        if inline.contains_key(directive) {
            return Err(ConfigError::Unsupported(format!(
                "inline <{directive}> authentication/proxy blocks are not supported"
            )));
        }
    }
    if inline.contains_key("connection") {
        return Err(ConfigError::Unsupported(
            "<connection> blocks are not supported; use a single remote".to_string(),
        ));
    }

    let global_proto = builder.proto.unwrap_or(Proto::Udp);
    let remotes: Vec<Remote> = builder
        .remotes
        .iter()
        .map(|remote| Remote {
            host: remote.host.clone(),
            port: remote.port,
            proto: remote.proto.unwrap_or(global_proto),
        })
        .collect();

    Ok(OvpnConfig {
        remotes,
        ca,
        cert,
        key,
        tls_wrap,
        cipher,
        auth: builder.auth,
        remote_cert_tls: builder.remote_cert_tls,
        tun_mtu: builder.tun_mtu,
        key_direction: builder.key_direction,
        warnings: builder.warnings,
        base_dir: base,
    })
}

fn material(
    name: &'static str,
    inline: Option<&String>,
    path: Option<PathBuf>,
) -> Result<Material, ConfigError> {
    if let Some(text) = inline {
        if text.trim().is_empty() {
            return Err(ConfigError::Missing(name));
        }
        return Ok(Material::Inline(text.clone()));
    }
    match path {
        Some(path) => Ok(Material::Path(path)),
        None => Err(ConfigError::Missing(name)),
    }
}

fn choose_cipher(builder: &mut Builder) -> Result<Cipher, ConfigError> {
    let mut candidates: Vec<String> = builder.data_ciphers.clone();
    if let Some(cipher) = &builder.cipher {
        candidates.push(cipher.clone());
    }
    if let Some(cipher) = &builder.fallback_cipher {
        candidates.push(cipher.clone());
    }
    if candidates.is_empty() {
        candidates.push("AES-256-GCM".to_string());
    }

    for name in &candidates {
        if let Some(cipher) = Cipher::parse(name) {
            if candidates
                .iter()
                .any(|other| other != name && Cipher::parse(other).is_none())
            {
                builder.warn(format!(
                    "ignored unsupported data cipher(s) in the preference list; using {name}"
                ));
            }
            return Ok(cipher);
        }
    }

    let legacy = candidates.iter().any(|name| Cipher::is_legacy(name));
    Err(ConfigError::Unsupported(if legacy {
        "CBC/CFB/OFB data ciphers are not supported; use AES-GCM or ChaCha20-Poly1305".to_string()
    } else {
        "none of the configured data ciphers is supported; use AES-GCM or ChaCha20-Poly1305"
            .to_string()
    }))
}

fn split_words(text: &str) -> Result<Vec<String>, String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        match quote {
            Some(q) if ch == q => quote = None,
            Some(_) if ch == '\\' => {
                if let Some(next) = chars.next() {
                    current.push(next);
                }
            }
            Some(_) => current.push(ch),
            None if ch == '"' || ch == '\'' => quote = Some(ch),
            None if ch.is_whitespace() => {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
            }
            None if ch == '\\' => {
                if let Some(next) = chars.next() {
                    current.push(next);
                }
            }
            None => current.push(ch),
        }
    }
    if quote.is_some() {
        return Err("unterminated quote".to_string());
    }
    if !current.is_empty() {
        words.push(current);
    }
    Ok(words)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PEM: &str = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n";

    fn common(extra: &str) -> String {
        format!(
            "client\ndev tun\nproto udp\nremote vpn.example.com 1194\n\
             ca ca.crt\ncert client.crt\nkey client.key\nremote-cert-tls server\n{extra}\n"
        )
    }

    #[test]
    fn parses_a_common_pki_profile() {
        let config = OvpnConfig::parse(&common(
            "auth SHA256\ncipher AES-256-GCM\ntls-auth ta.key 1\nverb 3\nroute 10.0.0.0 255.0.0.0\ndhcp-option DNS 10.8.0.1",
        ))
        .unwrap();

        assert_eq!(config.remotes.len(), 1);
        assert_eq!(config.remote().host, "vpn.example.com");
        assert_eq!(config.remote().port, 1194);
        assert_eq!(config.remote().proto, Proto::Udp);
        assert_eq!(config.auth, AuthDigest::Sha256);
        assert_eq!(config.cipher, Cipher::Aes256Gcm);
        assert_eq!(config.remote_cert_tls, Some(RemoteCertTls::Server));
        assert_eq!(config.tun_mtu, 1500);
        assert_eq!(config.tls_wrap.as_ref().unwrap().mode, TlsWrapMode::Auth);
        assert_eq!(config.tls_wrap.as_ref().unwrap().direction, Some(1));
        assert!(config.warnings.iter().any(|w| w.contains("route")));
        assert!(config.warnings.iter().any(|w| w.contains("dhcp-option")));
        assert!(!config.warnings.iter().any(|w| w.contains("unknown")));
    }

    #[test]
    fn supports_inline_material_and_tls_crypt() {
        let text = format!(
            "client\ndev tun\nproto tcp-client\nremote 203.0.113.7 443\n\
             <ca>\n{PEM}</ca>\n<cert>\n{PEM}</cert>\n<key>\n{PEM}</key>\n\
             <tls-crypt>\n-----BEGIN OpenVPN Static key V1-----\n{}\n-----END OpenVPN Static key V1-----\n</tls-crypt>\n",
            "00".repeat(256)
        );
        let config = OvpnConfig::parse(&text).unwrap();
        assert_eq!(config.remote().proto, Proto::Tcp);
        assert_eq!(config.ca.inline().unwrap().trim(), PEM.trim());
        let wrap = config.tls_wrap.as_ref().unwrap();
        assert_eq!(wrap.mode, TlsWrapMode::Crypt);
        assert!(
            wrap.material
                .inline()
                .unwrap()
                .contains("BEGIN OpenVPN Static key")
        );
    }

    #[test]
    fn selects_the_first_supported_data_cipher() {
        let text = common("data-ciphers AES-256-CBC:CHACHA20-POLY1305:AES-128-GCM");
        let config = OvpnConfig::parse(&text).unwrap();
        assert_eq!(config.cipher, Cipher::ChaCha20Poly1305);
        assert!(
            config
                .warnings
                .iter()
                .any(|w| w.contains("unsupported data cipher"))
        );
    }

    #[test]
    fn rejects_cbc_only_profiles() {
        let error = OvpnConfig::parse(&common("cipher AES-256-CBC")).unwrap_err();
        assert!(matches!(error, ConfigError::Unsupported(_)));
        assert!(error.to_string().contains("CBC"));
    }

    #[test]
    fn rejects_unsupported_features_explicitly() {
        for (extra, needle) in [
            ("auth-user-pass secrets.txt", "auth-user-pass"),
            ("dev tap", "dev tap"),
            ("proto udp6", "IPv6"),
            ("comp-lzo", "compression"),
            ("http-proxy proxy.example.com 8080", "proxy"),
            ("<connection>\nremote a 1194\n</connection>", "connection"),
            ("tls-crypt-v2 client.key", "tls-crypt-v2"),
        ] {
            let text = common(extra);
            let error = OvpnConfig::parse(&text).unwrap_err();
            assert!(
                error
                    .to_string()
                    .to_lowercase()
                    .contains(&needle.to_lowercase()),
                "{extra}: {error}"
            );
        }
    }

    #[test]
    fn rejects_missing_required_options() {
        let missing_ca = "client\ndev tun\nremote a 1194\ncert c\nkey k\n";
        assert!(matches!(
            OvpnConfig::parse(missing_ca).unwrap_err(),
            ConfigError::Missing("ca")
        ));

        let missing_remote = "client\ndev tun\nca c\ncert c\nkey k\n";
        assert!(matches!(
            OvpnConfig::parse(missing_remote).unwrap_err(),
            ConfigError::Missing("remote")
        ));

        let missing_client = "dev tun\nremote a 1194\nca c\ncert c\nkey k\n";
        assert!(matches!(
            OvpnConfig::parse(missing_client).unwrap_err(),
            ConfigError::Missing("client")
        ));

        let missing_key = "client\ndev tun\nremote a 1194\nca c\ncert c\n";
        assert!(matches!(
            OvpnConfig::parse(missing_key).unwrap_err(),
            ConfigError::Missing("key")
        ));
    }

    #[test]
    fn tolerates_comments_crlf_and_quoted_paths() {
        let text = "\u{feff}# comment\r\nclient\r\ndev tun\r\nproto udp4\r\n\
                    remote \"vpn.example.com\" 1194\r\n\
                    ca \"ca cert.pem\"\r\ncert cert.pem\r\nkey key.pem\r\n\
                    remote-cert-tls server\r\n; trailing comment\r\n";
        let text = text.trim_start_matches('\u{feff}');
        let config = OvpnConfig::parse(text).unwrap();
        assert_eq!(config.remote().host, "vpn.example.com");
        assert_eq!(config.ca.path().unwrap().to_string_lossy(), "ca cert.pem");
    }

    #[test]
    fn applies_global_key_direction_and_proto() {
        let text = common("tls-auth ta.key\nkey-direction 1").replace("proto udp", "proto tcp");
        let config = OvpnConfig::parse(&text).unwrap();
        assert_eq!(config.remote().proto, Proto::Tcp);
        assert_eq!(config.tls_wrap.as_ref().unwrap().direction, Some(1));
        assert_eq!(config.key_direction, Some(1));
    }

    #[test]
    fn debug_redacts_inline_private_material() {
        let secret = "-----BEGIN PRIVATE KEY-----\nSUPERSECRET\n-----END PRIVATE KEY-----";
        let text = format!(
            "client\ndev tun\nremote a 1194\n<ca>\n{PEM}</ca>\n<cert>\n{PEM}</cert>\n<key>\n{secret}\n</key>\n"
        );
        let config = OvpnConfig::parse(&text).unwrap();
        let debug = format!("{config:?}");
        assert!(!debug.contains("SUPERSECRET"));
        assert!(debug.contains("redacted"));
        assert!(!debug.contains(PEM));
    }

    #[test]
    fn options_string_and_peer_info_are_stable() {
        let config = OvpnConfig::parse(&common("auth SHA256")).unwrap();
        assert!(config.options_string().contains("proto UDPv4"));
        assert!(config.options_string().contains("cipher AES-256-GCM"));
        assert!(config.options_string().contains("key-method 2"));
        assert!(config.peer_info().contains("IV_NCP=2"));
        assert!(config.peer_info().contains("IV_CIPHERS=AES-256-GCM"));
    }

    #[test]
    fn material_loading_uses_the_profile_directory() {
        let directory = std::env::temp_dir().join(format!(
            "rfb-openvpn-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("ca.pem"), PEM).unwrap();
        std::fs::write(directory.join("client.crt"), PEM).unwrap();
        std::fs::write(directory.join("client.key"), PEM).unwrap();

        let text = common("").replace("ca ca.crt", "ca ca.pem");
        let config = OvpnConfig::parse_with_base(&text, Some(directory.clone())).unwrap();
        let material = config.load_material().unwrap();
        assert_eq!(material.ca_pem, PEM.as_bytes());
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn quoted_values_are_unquoted() {
        assert_eq!(
            split_words("remote \"vpn.example.com\" 443 tcp-client").unwrap(),
            vec!["remote", "vpn.example.com", "443", "tcp-client"]
        );
        assert_eq!(split_words("ca 'a b.pem'").unwrap(), vec!["ca", "a b.pem"]);
        assert!(split_words("ca \"unterminated").is_err());
    }
}

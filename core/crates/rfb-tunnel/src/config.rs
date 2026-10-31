//! A wg-quick subset: parsing, validation and `AllowedIPs` matching.
//!
//! The parser accepts the parts of a `wg-quick` file that matter for an
//! in-app tunnel: interface addresses, DNS, MTU and listen port, and per peer
//! public/pre-shared keys, endpoint, allowed IPs and keepalive. Script hooks
//! (`PreUp`, `PostUp`, `PreDown`, `PostDown`) are never executed; they and any
//! unknown key produce a warning instead of silently disappearing.
//!
//! The `Debug` implementations of everything that can hold secrets are
//! redacted.

use std::fmt;
use std::net::{IpAddr, Ipv6Addr};
use std::str::FromStr;

use ipnet::IpNet;

use crate::error::ConfigError;
use crate::keys::{PresharedKey, PrivateKey, PublicKey};

/// Smallest accepted inner MTU.
pub const MIN_MTU: u16 = 1280;
/// Largest accepted inner MTU.
pub const MAX_MTU: u16 = 1440;

/// Platform default inner MTU: 1420 on macOS (1500 byte paths, no PPPoE),
/// 1280 elsewhere (the IPv6 minimum, safe on cellular).
pub fn default_mtu() -> u16 {
    if cfg!(target_os = "macos") {
        1420
    } else {
        1280
    }
}

/// The host part of a peer endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EndpointHost {
    /// A literal address; no DNS lookup is needed.
    Ip(IpAddr),
    /// A name that must be resolved through the system resolver before the
    /// tunnel starts.
    Name(String),
}

/// The UDP endpoint of the WireGuard peer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    /// Host name or literal address.
    pub host: EndpointHost,
    /// UDP port, always non-zero.
    pub port: u16,
}

impl Endpoint {
    /// Parses `host:port`, `1.2.3.4:port` or `[v6]:port`.
    pub fn parse(text: &str) -> Result<Self, ConfigError> {
        let text = text.trim();
        if text.is_empty() {
            return Err(ConfigError::MissingField("Endpoint"));
        }

        if let Some(rest) = text.strip_prefix('[') {
            let (host, rest) = rest
                .split_once(']')
                .ok_or_else(|| ConfigError::InvalidValue {
                    field: "Endpoint",
                    detail: "missing closing ']' after the IPv6 address".to_string(),
                })?;
            let port = rest
                .strip_prefix(':')
                .ok_or_else(|| ConfigError::InvalidValue {
                    field: "Endpoint",
                    detail: "missing ':' before the port".to_string(),
                })?;
            let host = Ipv6Addr::from_str(host).map_err(|_| ConfigError::InvalidValue {
                field: "Endpoint",
                detail: "the bracketed host is not an IPv6 address".to_string(),
            })?;
            return Ok(Self {
                host: EndpointHost::Ip(IpAddr::V6(host)),
                port: parse_port(port)?,
            });
        }

        let (host, port) = text
            .rsplit_once(':')
            .ok_or_else(|| ConfigError::InvalidValue {
                field: "Endpoint",
                detail: "expected host:port".to_string(),
            })?;
        if host.is_empty() {
            return Err(ConfigError::InvalidValue {
                field: "Endpoint",
                detail: "the host is empty".to_string(),
            });
        }
        if host.contains(':') {
            return Err(ConfigError::InvalidValue {
                field: "Endpoint",
                detail: "IPv6 addresses must be written as [address]:port".to_string(),
            });
        }
        let host = match IpAddr::from_str(host) {
            Ok(ip) => EndpointHost::Ip(ip),
            Err(_) => EndpointHost::Name(host.to_string()),
        };
        Ok(Self {
            host,
            port: parse_port(port)?,
        })
    }
}

fn parse_port(text: &str) -> Result<u16, ConfigError> {
    let port = text
        .trim()
        .parse::<u16>()
        .map_err(|_| ConfigError::InvalidValue {
            field: "Endpoint",
            detail: "the port is not a number".to_string(),
        })?;
    if port == 0 {
        return Err(ConfigError::InvalidValue {
            field: "Endpoint",
            detail: "the port must be between 1 and 65535".to_string(),
        });
    }
    Ok(port)
}

impl fmt::Display for Endpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.host {
            EndpointHost::Ip(IpAddr::V6(ip)) => write!(f, "[{ip}]:{}", self.port),
            EndpointHost::Ip(ip) => write!(f, "{ip}:{}", self.port),
            EndpointHost::Name(name) => write!(f, "{name}:{}", self.port),
        }
    }
}

/// `[Interface]` settings that are not secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterfaceConfig {
    /// Inner addresses with prefix lengths, in configuration order.
    pub addresses: Vec<IpNet>,
    /// Inner DNS servers (literal addresses only).
    pub dns: Vec<IpAddr>,
    /// Inner MTU, already clamped to [`MIN_MTU`]..=[`MAX_MTU`].
    pub mtu: u16,
    /// Outer UDP listen port; `0` means an ephemeral port.
    pub listen_port: u16,
}

/// One `[Peer]` entry.
#[derive(Debug, Clone)]
pub struct PeerConfig {
    /// Peer static public key.
    pub public_key: PublicKey,
    /// Optional pre-shared key.
    pub preshared_key: Option<PresharedKey>,
    /// UDP endpoint; may be absent for a responder-only configuration.
    pub endpoint: Option<Endpoint>,
    /// Networks routed through this peer.
    pub allowed_ips: Vec<IpNet>,
    /// `PersistentKeepalive` in seconds; `None` for `off`/`0`.
    pub persistent_keepalive: Option<u16>,
}

impl PeerConfig {
    /// Returns the longest matching prefix length for `ip`, if any.
    pub fn match_prefix(&self, ip: IpAddr) -> Option<u8> {
        self.allowed_ips
            .iter()
            .filter(|net| net.contains(&ip))
            .map(IpNet::prefix_len)
            .max()
    }
}

/// Parsed configuration, without secrets in `Debug`.
#[derive(Debug, Clone)]
pub struct WireGuardConfig {
    /// Interface settings.
    pub interface: InterfaceConfig,
    /// Peers, in configuration order.
    pub peers: Vec<PeerConfig>,
    /// Non-fatal parser findings, suitable for display in the UI.
    pub warnings: Vec<String>,
}

impl WireGuardConfig {
    /// Parses and validates a wg-quick configuration.
    pub fn parse(text: &str) -> Result<ParsedConfig, ConfigError> {
        parse_config(text)
    }

    /// Returns the peer whose `AllowedIPs` contains `ip` with the longest
    /// prefix (the first peer wins a tie).
    pub fn peer_for(&self, ip: IpAddr) -> Option<&PeerConfig> {
        self.peer_match(ip).map(|(peer, _)| peer)
    }

    /// Like [`Self::peer_for`] but also returns the matched prefix length.
    pub fn peer_match(&self, ip: IpAddr) -> Option<(&PeerConfig, u8)> {
        let mut best: Option<(&PeerConfig, u8)> = None;
        for peer in &self.peers {
            if let Some(prefix) = peer.match_prefix(ip)
                && best.is_none_or(|(_, current)| prefix > current)
            {
                best = Some((peer, prefix));
            }
        }
        best
    }

    /// Returns whether any peer covers `ip`.
    pub fn has_route(&self, ip: IpAddr) -> bool {
        self.peer_match(ip).is_some()
    }
}

/// A parsed configuration plus its private key.
#[derive(Debug, Clone)]
pub struct ParsedConfig {
    /// Non-secret configuration.
    pub config: WireGuardConfig,
    /// The `[Interface]` private key.
    pub private_key: PrivateKey,
}

#[derive(Clone, Copy)]
enum Section {
    Interface,
    Peer(usize),
    Ignored,
}

#[derive(Default)]
struct InterfaceBuilder {
    private_key: Option<PrivateKey>,
    addresses: Vec<IpNet>,
    dns: Vec<IpAddr>,
    mtu: Option<u16>,
    listen_port: u16,
}

#[derive(Default)]
struct PeerBuilder {
    public_key: Option<PublicKey>,
    preshared_key: Option<PresharedKey>,
    endpoint: Option<Endpoint>,
    allowed_ips: Vec<IpNet>,
    persistent_keepalive: Option<u16>,
}

fn strip_comment(line: &str) -> &str {
    match line.find(['#', ';']) {
        Some(index) => line[..index].trim_end(),
        None => line,
    }
}

fn parse_config(text: &str) -> Result<ParsedConfig, ConfigError> {
    let mut warnings = Vec::new();
    let mut interface: Option<InterfaceBuilder> = None;
    let mut peers: Vec<PeerBuilder> = Vec::new();
    let mut section: Option<Section> = None;

    for (index, raw) in text.lines().enumerate() {
        let line = strip_comment(raw.trim()).trim();
        if line.is_empty() {
            continue;
        }

        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            let name = name.trim();
            match name {
                "Interface" => {
                    if interface.is_some() {
                        return Err(ConfigError::DuplicateSection("Interface"));
                    }
                    interface = Some(InterfaceBuilder::default());
                    section = Some(Section::Interface);
                }
                "Peer" => {
                    peers.push(PeerBuilder::default());
                    section = Some(Section::Peer(peers.len() - 1));
                }
                other => {
                    warnings.push(format!("ignored unsupported section [{other}]"));
                    section = Some(Section::Ignored);
                }
            }
            continue;
        }

        let (key, value) = line.split_once('=').ok_or(ConfigError::Syntax(index + 1))?;
        let key = key.trim();
        let value = value.trim();
        if key.is_empty() {
            return Err(ConfigError::Syntax(index + 1));
        }

        match section {
            Some(Section::Interface) => {
                let builder = interface
                    .as_mut()
                    .ok_or(ConfigError::MissingSection("Interface"))?;
                parse_interface_key(builder, key, value, &mut warnings)?;
            }
            Some(Section::Peer(index)) => {
                let builder = peers.get_mut(index).ok_or(ConfigError::Syntax(index + 1))?;
                parse_peer_key(builder, key, value, &mut warnings)?;
            }
            Some(Section::Ignored) => {}
            None => {
                return Err(ConfigError::InvalidValue {
                    field: "configuration",
                    detail: "a key appears before any section header".to_string(),
                });
            }
        }
    }

    let mut interface = interface.ok_or(ConfigError::MissingSection("Interface"))?;
    let private_key = interface
        .private_key
        .take()
        .ok_or(ConfigError::MissingField("PrivateKey"))?;
    if interface.addresses.is_empty() {
        return Err(ConfigError::MissingField("Address"));
    }
    if peers.is_empty() {
        return Err(ConfigError::MissingSection("Peer"));
    }

    let mut peer_configs = Vec::with_capacity(peers.len());
    for peer in peers {
        let public_key = peer
            .public_key
            .ok_or(ConfigError::MissingField("Peer.PublicKey"))?;
        if peer.allowed_ips.is_empty() {
            return Err(ConfigError::MissingField("Peer.AllowedIPs"));
        }
        peer_configs.push(PeerConfig {
            public_key,
            preshared_key: peer.preshared_key,
            endpoint: peer.endpoint,
            allowed_ips: peer.allowed_ips,
            persistent_keepalive: peer.persistent_keepalive,
        });
    }

    let mtu = interface.mtu.unwrap_or_else(default_mtu);
    let mut config = WireGuardConfig {
        interface: InterfaceConfig {
            addresses: interface.addresses,
            dns: interface.dns,
            mtu,
            listen_port: interface.listen_port,
        },
        peers: peer_configs,
        warnings,
    };

    if config
        .interface
        .addresses
        .iter()
        .any(|net| net.addr().is_ipv6())
    {
        config.warnings.push(
            "inner IPv6 addresses are parsed but not used yet; only IPv4 is supported".to_string(),
        );
    }

    for server in &config.interface.dns {
        if !config.has_route(*server) {
            config.warnings.push(format!(
                "DNS server {server} is not covered by AllowedIPs; queries may be dropped"
            ));
        }
    }

    if config.peers.len() > 1 {
        config.warnings.push(
            "multiple peers parsed; this version can only run one peer per tunnel".to_string(),
        );
    }

    Ok(ParsedConfig {
        config,
        private_key,
    })
}

fn parse_interface_key(
    builder: &mut InterfaceBuilder,
    key: &str,
    value: &str,
    warnings: &mut Vec<String>,
) -> Result<(), ConfigError> {
    match key {
        "PrivateKey" => {
            if builder.private_key.is_some() {
                warnings.push("duplicate PrivateKey; using the last value".to_string());
            }
            builder.private_key = Some(
                PrivateKey::from_base64(value)
                    .map_err(|_| ConfigError::InvalidKey("PrivateKey"))?,
            );
        }
        "Address" => {
            for entry in value.split(',') {
                let entry = entry.trim();
                if entry.is_empty() {
                    continue;
                }
                let net = IpNet::from_str(entry).map_err(|_| ConfigError::InvalidValue {
                    field: "Address",
                    detail: "expected an address with a prefix length, for example 10.0.0.2/24"
                        .to_string(),
                })?;
                builder.addresses.push(net);
            }
        }
        "DNS" => {
            for entry in value.split(',') {
                let entry = entry.trim();
                if entry.is_empty() {
                    continue;
                }
                match IpAddr::from_str(entry) {
                    Ok(ip) => builder.dns.push(ip),
                    Err(_) => warnings.push(format!(
                        "DNS entry {entry} is not an IP address and was ignored"
                    )),
                }
            }
        }
        "MTU" => {
            let mtu = value
                .parse::<u16>()
                .map_err(|_| ConfigError::InvalidValue {
                    field: "MTU",
                    detail: "expected an integer".to_string(),
                })?;
            let clamped = mtu.clamp(MIN_MTU, MAX_MTU);
            if clamped != mtu {
                warnings.push(format!(
                    "MTU {mtu} is outside {MIN_MTU}-{MAX_MTU}; using {clamped}"
                ));
            }
            builder.mtu = Some(clamped);
        }
        "ListenPort" => {
            builder.listen_port = value
                .parse::<u16>()
                .map_err(|_| ConfigError::InvalidValue {
                    field: "ListenPort",
                    detail: "expected a number between 0 and 65535".to_string(),
                })?;
        }
        "PreUp" | "PostUp" | "PreDown" | "PostDown" => {
            warnings.push(format!(
                "ignored {key}: configuration scripts are never executed"
            ));
        }
        "Table" | "SaveConfig" | "FwMark" => {
            warnings.push(format!("ignored {key}: not supported by this tunnel"));
        }
        other => warnings.push(format!("ignored unknown [Interface] key {other}")),
    }
    Ok(())
}

fn parse_peer_key(
    builder: &mut PeerBuilder,
    key: &str,
    value: &str,
    warnings: &mut Vec<String>,
) -> Result<(), ConfigError> {
    match key {
        "PublicKey" => {
            builder.public_key = Some(
                PublicKey::from_base64(value)
                    .map_err(|_| ConfigError::InvalidKey("Peer.PublicKey"))?,
            );
        }
        "PresharedKey" => {
            builder.preshared_key = Some(
                PresharedKey::from_base64(value)
                    .map_err(|_| ConfigError::InvalidKey("Peer.PresharedKey"))?,
            );
        }
        "Endpoint" => {
            builder.endpoint = Some(Endpoint::parse(value)?);
        }
        "AllowedIPs" => {
            for entry in value.split(',') {
                let entry = entry.trim();
                if entry.is_empty() {
                    continue;
                }
                let net = IpNet::from_str(entry).map_err(|_| ConfigError::InvalidValue {
                    field: "Peer.AllowedIPs",
                    detail: "expected a network in CIDR notation".to_string(),
                })?;
                builder.allowed_ips.push(net);
            }
        }
        "PersistentKeepalive" => {
            if value.eq_ignore_ascii_case("off") || value == "0" {
                builder.persistent_keepalive = None;
            } else {
                let seconds = value
                    .parse::<u16>()
                    .map_err(|_| ConfigError::InvalidValue {
                        field: "PersistentKeepalive",
                        detail: "expected a number of seconds or off".to_string(),
                    })?;
                builder.persistent_keepalive = (seconds != 0).then_some(seconds);
            }
        }
        _ => warnings.push(format!("ignored unknown [Peer] key {key}")),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::KeyPair;

    fn config_text(
        private: &str,
        peer_public: &str,
        extra_interface: &str,
        extra_peer: &str,
    ) -> String {
        format!(
            "[Interface]\nPrivateKey = {private}\nAddress = 10.66.66.2/24\n{extra_interface}\n\
             [Peer]\nPublicKey = {peer_public}\nAllowedIPs = 10.66.66.0/24\n{extra_peer}\n"
        )
    }

    #[test]
    fn parses_common_fields() {
        let pair = KeyPair::generate();
        let peer = KeyPair::generate();
        let text = format!(
            "[Interface]\nPrivateKey = {}\nAddress = 10.66.66.2/24, fd00::2/64\n\
             DNS = 10.66.66.1, 10.66.66.53\nMTU = 1300\nListenPort = 51820\n\
             [Peer]\nPublicKey = {}\nPresharedKey = {}\nEndpoint = vpn.example.com:51820\n\
             AllowedIPs = 10.66.66.0/24, 192.168.50.0/24\nPersistentKeepalive = 25\n",
            pair.private().encode_base64(),
            peer.public().encode_base64(),
            KeyPair::generate().private().encode_base64(),
        );
        let parsed = WireGuardConfig::parse(&text).unwrap();
        let config = parsed.config;

        assert_eq!(config.interface.addresses.len(), 2);
        assert_eq!(config.interface.dns.len(), 2);
        assert_eq!(config.interface.mtu, 1300);
        assert_eq!(config.interface.listen_port, 51820);
        assert_eq!(config.peers.len(), 1);
        assert_eq!(config.peers[0].endpoint.as_ref().unwrap().port, 51820);
        assert_eq!(
            config.peers[0].persistent_keepalive,
            Some(25),
            "keepalive should be parsed"
        );
        assert_eq!(config.peers[0].allowed_ips.len(), 2);
        assert!(
            config
                .warnings
                .iter()
                .all(|warning| warning.contains("IPv6")),
            "only the inner IPv6 notice is expected: {:?}",
            config.warnings
        );
        assert_eq!(parsed.private_key.public_key(), pair.private().public_key());
    }

    #[test]
    fn tolerates_crlf_comments_and_spacing() {
        let pair = KeyPair::generate();
        let peer = KeyPair::generate();
        let text = format!(
            "# a comment\r\n[Interface]\r\n  PrivateKey = {}  # inline\r\nAddress = 10.0.0.2/24\r\n\
             ; another comment\r\n[Peer]\r\nPublicKey = {}\r\nAllowedIPs = 10.0.0.0/24\r\n",
            pair.private().encode_base64(),
            peer.public().encode_base64(),
        );
        let parsed = WireGuardConfig::parse(&text).unwrap();
        assert_eq!(parsed.config.interface.addresses.len(), 1);
        assert_eq!(parsed.config.peers.len(), 1);
        assert!(parsed.config.warnings.is_empty());
    }

    #[test]
    fn rejects_missing_required_fields() {
        let pair = KeyPair::generate();
        let peer = KeyPair::generate();
        let private = pair.private().encode_base64();
        let public = peer.public().encode_base64();

        let missing_interface = format!("[Peer]\nPublicKey = {public}\nAllowedIPs = 10.0.0.0/24\n");
        assert!(matches!(
            WireGuardConfig::parse(&missing_interface).unwrap_err(),
            ConfigError::MissingSection("Interface")
        ));

        let missing_private = format!(
            "[Interface]\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = {public}\nAllowedIPs = 10.0.0.0/24\n"
        );
        assert!(matches!(
            WireGuardConfig::parse(&missing_private).unwrap_err(),
            ConfigError::MissingField("PrivateKey")
        ));

        let missing_address = format!(
            "[Interface]\nPrivateKey = {private}\n[Peer]\nPublicKey = {public}\nAllowedIPs = 10.0.0.0/24\n"
        );
        assert!(matches!(
            WireGuardConfig::parse(&missing_address).unwrap_err(),
            ConfigError::MissingField("Address")
        ));

        let missing_peer = format!("[Interface]\nPrivateKey = {private}\nAddress = 10.0.0.2/24\n");
        assert!(matches!(
            WireGuardConfig::parse(&missing_peer).unwrap_err(),
            ConfigError::MissingSection("Peer")
        ));

        let missing_public = format!(
            "[Interface]\nPrivateKey = {private}\nAddress = 10.0.0.2/24\n[Peer]\nAllowedIPs = 10.0.0.0/24\n"
        );
        assert!(matches!(
            WireGuardConfig::parse(&missing_public).unwrap_err(),
            ConfigError::MissingField("Peer.PublicKey")
        ));

        let missing_allowed = format!(
            "[Interface]\nPrivateKey = {private}\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = {public}\n"
        );
        assert!(matches!(
            WireGuardConfig::parse(&missing_allowed).unwrap_err(),
            ConfigError::MissingField("Peer.AllowedIPs")
        ));
    }

    #[test]
    fn rejects_invalid_keys_without_echoing_them() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let text = format!(
            "[Interface]\nPrivateKey = not-a-key\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = {public}\nAllowedIPs = 10.0.0.0/24\n"
        );
        let error = WireGuardConfig::parse(&text).unwrap_err();
        let message = error.to_string();
        assert!(!message.contains("not-a-key"));
        assert!(matches!(error, ConfigError::InvalidKey("PrivateKey")));

        let private = pair.private().encode_base64();
        let text = format!(
            "[Interface]\nPrivateKey = {private}\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = bad\nAllowedIPs = 10.0.0.0/24\n"
        );
        let error = WireGuardConfig::parse(&text).unwrap_err();
        assert!(!error.to_string().contains("bad"));
    }

    #[test]
    fn clamps_mtu_and_warns() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let low = config_text(&pair.private().encode_base64(), &public, "MTU = 900", "");
        let parsed = WireGuardConfig::parse(&low).unwrap();
        assert_eq!(parsed.config.interface.mtu, MIN_MTU);
        assert!(parsed.config.warnings.iter().any(|w| w.contains("MTU 900")));

        let high = config_text(&pair.private().encode_base64(), &public, "MTU = 9000", "");
        let parsed = WireGuardConfig::parse(&high).unwrap();
        assert_eq!(parsed.config.interface.mtu, MAX_MTU);
    }

    #[test]
    fn normalises_keepalive() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let off = config_text(
            &pair.private().encode_base64(),
            &public,
            "",
            "PersistentKeepalive = off\n",
        );
        assert_eq!(
            WireGuardConfig::parse(&off).unwrap().config.peers[0].persistent_keepalive,
            None
        );

        let zero = config_text(
            &pair.private().encode_base64(),
            &public,
            "",
            "PersistentKeepalive = 0\n",
        );
        assert_eq!(
            WireGuardConfig::parse(&zero).unwrap().config.peers[0].persistent_keepalive,
            None
        );
    }

    #[test]
    fn warns_about_scripts_and_unknown_keys() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let text = config_text(
            &pair.private().encode_base64(),
            &public,
            "PostUp = touch /tmp/owned\nTable = off",
            "PersistentKeepalive = 15\nSomethingNew = 1\n",
        );
        let parsed = WireGuardConfig::parse(&text).unwrap();
        let warnings = parsed.config.warnings.join("\n");
        assert!(warnings.contains("PostUp"));
        assert!(warnings.contains("never executed"));
        assert!(warnings.contains("Table"));
        assert!(warnings.contains("SomethingNew"));
    }

    #[test]
    fn dns_names_are_ignored_with_a_warning() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let text = config_text(
            &pair.private().encode_base64(),
            &public,
            "DNS = 10.66.66.1, corp.example.com",
            "",
        );
        let parsed = WireGuardConfig::parse(&text).unwrap();
        assert_eq!(
            parsed.config.interface.dns,
            vec![IpAddr::from([10, 66, 66, 1])]
        );
        assert!(
            parsed
                .config
                .warnings
                .iter()
                .any(|w| w.contains("corp.example.com"))
        );
    }

    #[test]
    fn warns_when_dns_is_outside_allowed_ips() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let text = config_text(
            &pair.private().encode_base64(),
            &public,
            "DNS = 1.1.1.1",
            "",
        );
        let parsed = WireGuardConfig::parse(&text).unwrap();
        assert!(parsed.config.warnings.iter().any(|w| w.contains("1.1.1.1")));
    }

    #[test]
    fn allowed_ips_longest_prefix_across_peers() {
        let pair = KeyPair::generate();
        let wide = KeyPair::generate();
        let narrow = KeyPair::generate();
        let text = format!(
            "[Interface]\nPrivateKey = {}\nAddress = 10.0.0.2/24\n\
             [Peer]\nPublicKey = {}\nAllowedIPs = 10.0.0.0/8, fd00::/8\n\
             [Peer]\nPublicKey = {}\nAllowedIPs = 10.1.0.0/16, 192.168.0.0/16\n",
            pair.private().encode_base64(),
            wide.public().encode_base64(),
            narrow.public().encode_base64(),
        );
        let config = WireGuardConfig::parse(&text).unwrap().config;
        assert_eq!(config.peers.len(), 2);

        let narrow_key = *narrow.public();
        let wide_key = *wide.public();

        assert_eq!(
            config.peer_match(IpAddr::from([10, 1, 2, 3])).unwrap().1,
            16
        );
        assert_eq!(
            config
                .peer_for(IpAddr::from([10, 1, 2, 3]))
                .unwrap()
                .public_key,
            narrow_key
        );
        assert_eq!(
            config
                .peer_for(IpAddr::from([10, 2, 3, 4]))
                .unwrap()
                .public_key,
            wide_key
        );
        assert_eq!(
            config
                .peer_for(IpAddr::from([192, 168, 1, 1]))
                .unwrap()
                .public_key,
            narrow_key
        );
        assert_eq!(
            config.peer_match(IpAddr::from([10, 1, 2, 3])).unwrap().1,
            16
        );
        assert!(config.has_route(IpAddr::from([10, 1, 2, 3])));
        assert!(!config.has_route(IpAddr::from([172, 16, 0, 1])));

        let v6 = "fd12:3456::1".parse::<IpAddr>().unwrap();
        assert_eq!(config.peer_for(v6).unwrap().public_key, wide_key);
        assert!(!config.has_route("2001:db8::1".parse::<IpAddr>().unwrap()));
    }

    #[test]
    fn duplicate_interface_section_is_rejected() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let text = format!(
            "[Interface]\nPrivateKey = {}\nAddress = 10.0.0.2/24\n\
             [Interface]\nPrivateKey = {}\nAddress = 10.0.0.3/24\n\
             [Peer]\nPublicKey = {public}\nAllowedIPs = 10.0.0.0/24\n",
            pair.private().encode_base64(),
            pair.private().encode_base64(),
        );
        assert!(matches!(
            WireGuardConfig::parse(&text).unwrap_err(),
            ConfigError::DuplicateSection("Interface")
        ));
    }

    #[test]
    fn parses_all_endpoint_shapes() {
        assert_eq!(
            Endpoint::parse("vpn.example.com:51820").unwrap(),
            Endpoint {
                host: EndpointHost::Name("vpn.example.com".to_string()),
                port: 51820
            }
        );
        assert_eq!(
            Endpoint::parse("203.0.113.7:443").unwrap(),
            Endpoint {
                host: EndpointHost::Ip(IpAddr::from([203, 0, 113, 7])),
                port: 443
            }
        );
        assert_eq!(
            Endpoint::parse("[fd00::1]:51820").unwrap(),
            Endpoint {
                host: EndpointHost::Ip("fd00::1".parse().unwrap()),
                port: 51820
            }
        );
        assert!(Endpoint::parse("vpn.example.com").is_err());
        assert!(Endpoint::parse("vpn.example.com:0").is_err());
        assert!(Endpoint::parse("fd00::1:51820").is_err());
        assert!(Endpoint::parse("[fd00::1]51820").is_err());
    }

    #[test]
    fn debug_redacts_private_and_preshared_keys() {
        let pair = KeyPair::generate();
        let public = KeyPair::generate().public().encode_base64();
        let psk = KeyPair::generate().private().encode_base64();
        let text = format!(
            "[Interface]\nPrivateKey = {}\nAddress = 10.0.0.2/24\n\
             [Peer]\nPublicKey = {public}\nPresharedKey = {psk}\nAllowedIPs = 10.0.0.0/24\n",
            pair.private().encode_base64(),
        );
        let parsed = WireGuardConfig::parse(&text).unwrap();
        let debug = format!("{parsed:?}");
        assert!(!debug.contains(&pair.private().encode_base64()));
        assert!(!debug.contains(&psk));
        assert!(debug.contains("redacted"));
    }
}

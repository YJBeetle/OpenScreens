//! `PUSH_REPLY` parsing.
//!
//! Only the IPv4 tun directives that matter to an in-process transport are
//! interpreted: `ifconfig`, `topology`, `route-gateway`, `route`,
//! `redirect-gateway`, `dhcp-option DNS`, `cipher`/`data-ciphers`, `auth`,
//! `peer-id` and `tun-mtu`. Unknown or OS-specific pushes produce warnings;
//! compression and IPv6-only pushes are rejected or warned about explicitly.

use std::fmt;
use std::net::Ipv4Addr;
use std::time::Duration;

use crate::cipher::{AuthDigest, Cipher};
use crate::error::TunnelError;

/// Inner interface topology announced by the server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Topology {
    /// Classic /30 point-to-point (`ifconfig local remote`).
    Net30,
    /// `ifconfig local netmask`.
    Subnet,
    /// Point-to-point with a /32 local address.
    P2p,
}

/// Inner interface addresses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IfConfig {
    /// Local tunnel address.
    pub(crate) local: Ipv4Addr,
    /// Netmask for subnet topology (255.255.255.252 for net30, /32 for p2p).
    pub(crate) netmask: Ipv4Addr,
    /// Prefix length derived from `netmask`.
    pub(crate) prefix: u8,
    /// Peer/gateway address for net30 and p2p.
    pub(crate) peer: Option<Ipv4Addr>,
}

impl IfConfig {
    #[cfg(test)]
    fn is_on_link(&self, ip: Ipv4Addr) -> bool {
        let mask = u32::from(self.netmask);
        (u32::from(ip) & mask) == (u32::from(self.local) & mask)
    }
}

/// One pushed IPv4 route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Route {
    /// Network address (host bits zeroed).
    pub(crate) network: Ipv4Addr,
    /// Prefix length.
    pub(crate) prefix: u8,
}

impl Route {
    fn new(addr: Ipv4Addr, prefix: u8) -> Self {
        let mask = prefix_mask(prefix);
        Self {
            network: Ipv4Addr::from(u32::from(addr) & mask),
            prefix,
        }
    }

    #[cfg(test)]
    fn contains(self, ip: Ipv4Addr) -> bool {
        (u32::from(ip) & prefix_mask(self.prefix)) == u32::from(self.network)
    }

    /// Whether this is the IPv4 default route.
    pub(crate) fn is_default(self) -> bool {
        self.prefix == 0
    }
}

fn prefix_mask(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - u32::from(prefix))
    }
}

fn mask_to_prefix(mask: Ipv4Addr) -> Option<u8> {
    let bits = u32::from(mask);
    let prefix = bits.count_ones() as u8;
    if bits == prefix_mask(prefix) {
        Some(prefix)
    } else {
        None
    }
}

/// Parsed push reply.
#[derive(Debug, Clone)]
pub(crate) struct PushReply {
    /// Inner interface.
    pub(crate) ifconfig: IfConfig,
    /// Gateway used for routes, when pushed.
    pub(crate) gateway: Option<Ipv4Addr>,
    /// Routes including a possible default route.
    pub(crate) routes: Vec<Route>,
    /// DNS servers (IPv4 only).
    pub(crate) dns: Vec<Ipv4Addr>,
    /// Cipher selected by the server, if pushed.
    pub(crate) cipher: Option<Cipher>,
    /// P_DATA_V2 peer id.
    pub(crate) peer_id: Option<u32>,
    /// Inner MTU.
    pub(crate) mtu: u16,
    /// Non-fatal findings.
    pub(crate) warnings: Vec<String>,
    /// Keepalive ping interval pushed by the server.
    pub(crate) ping: Option<Duration>,
}

impl PushReply {
    /// Returns whether a default route was pushed.
    #[cfg(test)]
    fn has_default_route(&self) -> bool {
        self.routes.iter().any(|route| route.is_default())
    }

    /// Gateway to use for the userspace stack's default route.
    pub(crate) fn stack_gateway(&self) -> Option<Ipv4Addr> {
        self.gateway.or(self.ifconfig.peer).or_else(|| {
            // A subnet topology usually has the gateway as the peer; if
            // the server did not push one, use the local address so the
            // stack still emits packets with a next hop.
            (self.ifconfig.prefix < 31).then_some(self.ifconfig.local)
        })
    }
}

fn invalid(detail: impl Into<String>) -> TunnelError {
    TunnelError::Protocol(detail.into())
}

/// Parses the text following `PUSH_REPLY,`.
pub(crate) fn parse_push_reply(text: &str) -> Result<PushReply, TunnelError> {
    let body = text
        .strip_prefix("PUSH_REPLY,")
        .or_else(|| text.strip_prefix("PUSH_REPLY"))
        .unwrap_or(text);
    let directives: Vec<String> = body
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(ToOwned::to_owned)
        .collect();
    if directives.is_empty() {
        return Err(invalid("PUSH_REPLY is empty"));
    }

    let mut warnings = Vec::new();
    let mut topology: Option<Topology> = None;
    let mut ifconfig_raw: Option<Vec<String>> = None;
    let mut gateway: Option<Ipv4Addr> = None;
    let mut routes: Vec<Route> = Vec::new();
    let mut redirect_default = false;
    let mut dns = Vec::new();
    let mut cipher = None;
    let mut peer_id = None;
    let mut mtu = 1500u16;
    let mut ping = None;

    for directive in &directives {
        let words: Vec<&str> = directive.split_whitespace().collect();
        let Some(name) = words.first().copied() else {
            continue;
        };
        match name.to_ascii_lowercase().as_str() {
            "ifconfig" => {
                if words.len() < 3 {
                    return Err(invalid("ifconfig needs local and remote/netmask"));
                }
                ifconfig_raw = Some(words[1..].iter().map(|word| word.to_string()).collect());
            }
            "topology" => {
                topology = Some(match words.get(1).copied().unwrap_or("") {
                    "subnet" => Topology::Subnet,
                    "net30" => Topology::Net30,
                    "p2p" => Topology::P2p,
                    other => {
                        warnings.push(format!("ignored unknown topology {other}"));
                        continue;
                    }
                });
            }
            "ifconfig-ipv6" | "route-ipv6" | "dhcp-option-ipv6" | "block-ipv6" => {
                warnings.push(format!("ignored {name}: IPv6 is not supported"));
            }
            "route-gateway" => {
                let Some(value) = words.get(1) else {
                    warnings.push("ignored route-gateway without a value".to_string());
                    continue;
                };
                if *value == "dhcp" {
                    warnings.push("ignored route-gateway dhcp".to_string());
                    continue;
                }
                if let Ok(ip) = value.parse::<Ipv4Addr>() {
                    gateway = Some(ip);
                } else {
                    warnings.push("ignored non-IPv4 route-gateway".to_string());
                }
            }
            "route" => {
                if words.len() < 3 {
                    warnings.push("ignored malformed route push".to_string());
                    continue;
                }
                let Ok(addr) = words[1].parse::<Ipv4Addr>() else {
                    warnings.push("ignored non-IPv4 route push".to_string());
                    continue;
                };
                let Ok(mask) = words[2].parse::<Ipv4Addr>() else {
                    warnings.push("ignored route with a non-IPv4 netmask".to_string());
                    continue;
                };
                let Some(prefix) = mask_to_prefix(mask) else {
                    warnings.push("ignored route with a non-contiguous netmask".to_string());
                    continue;
                };
                if let Some(route_gateway) = words.get(3) {
                    if *route_gateway == "net_gateway" {
                        warnings.push(
                            "ignored route via net_gateway: host-network routing is not used"
                                .to_string(),
                        );
                        continue;
                    }
                    if *route_gateway != "vpn_gateway" && route_gateway.parse::<Ipv4Addr>().is_err()
                    {
                        warnings.push("ignored route with an unknown gateway".to_string());
                        continue;
                    }
                }
                routes.push(Route::new(addr, prefix));
            }
            "redirect-gateway" | "redirect-private" => {
                let mut ipv4 = true;
                for flag in &words[1..] {
                    if *flag == "!ipv4" {
                        ipv4 = false;
                    }
                }
                if ipv4 {
                    redirect_default = true;
                }
            }
            "dhcp-option" => match (words.get(1), words.get(2)) {
                (Some(kind), Some(value)) if kind.eq_ignore_ascii_case("DNS") => {
                    if let Ok(ip) = value.parse::<Ipv4Addr>() {
                        dns.push(ip);
                    } else {
                        warnings.push("ignored non-IPv4 DHCP DNS server".to_string());
                    }
                }
                (Some(kind), Some(_value)) if kind.eq_ignore_ascii_case("DNS6") => {
                    warnings.push("ignored DNS6: IPv6 is not supported".to_string());
                }
                (Some(kind), _) if kind.eq_ignore_ascii_case("DOMAIN") => {}
                _ => {}
            },
            "cipher" => {
                let Some(name) = words.get(1) else {
                    warnings.push("ignored cipher push without a value".to_string());
                    continue;
                };
                cipher = Some(Cipher::parse(name).ok_or_else(|| {
                    TunnelError::Unsupported(format!("the server pushed unsupported cipher {name}"))
                })?);
            }
            "data-ciphers" => {
                let Some(list) = words.get(1) else {
                    continue;
                };
                let mut selected = None;
                for item in list.split(':') {
                    let item = item.trim().trim_start_matches('?');
                    if let Some(candidate) = Cipher::parse(item) {
                        selected = Some(candidate);
                        break;
                    }
                }
                match selected {
                    Some(selected) => cipher = Some(selected),
                    None => {
                        return Err(TunnelError::Unsupported(
                            "the server pushed no supported data cipher".to_string(),
                        ));
                    }
                }
            }
            "auth" => {
                let Some(name) = words.get(1) else {
                    continue;
                };
                AuthDigest::parse(name).ok_or_else(|| {
                    TunnelError::Unsupported(format!(
                        "the server pushed unsupported auth digest {name}"
                    ))
                })?;
            }
            "peer-id" => {
                let value = words
                    .get(1)
                    .and_then(|word| word.parse::<u32>().ok())
                    .ok_or_else(|| invalid("peer-id is not a number"))?;
                if value > 0x00ff_ffff {
                    return Err(invalid("peer-id does not fit in 24 bits"));
                }
                peer_id = Some(value);
            }
            "tun-mtu" | "mtu" => {
                if let Some(value) = words.get(1).and_then(|word| word.parse::<u16>().ok()) {
                    mtu = value.clamp(1280, 1500);
                    if mtu != value {
                        warnings.push(format!("clamped pushed MTU {value} to {mtu}"));
                    }
                }
            }
            "compress" | "comp-lzo" => {
                return Err(TunnelError::Unsupported(
                    "the server pushed compression, which is not supported".to_string(),
                ));
            }
            "ping" => {
                if let Some(value) = words.get(1) {
                    match value.parse::<u32>() {
                        Ok(seconds) if seconds > 0 => {
                            ping = Some(Duration::from_secs(u64::from(seconds)));
                        }
                        _ => warnings.push("ignored malformed ping push".to_string()),
                    }
                }
            }
            "ping-restart"
            | "ping-exit"
            | "inactive"
            | "explicit-exit-notify"
            | "sndbuf"
            | "rcvbuf"
            | "route-metric"
            | "route-delay"
            | "register-dns"
            | "block-outside-dns"
            | "auth-token"
            | "auth-token-user"
            | "key-derivation" => {}
            other => warnings.push(format!("ignored unknown PUSH_REPLY directive {other}")),
        }
    }

    let Some(raw) = ifconfig_raw else {
        return Err(invalid("PUSH_REPLY did not include ifconfig"));
    };
    if raw.len() < 2 {
        return Err(invalid("ifconfig needs local and remote/netmask"));
    }
    let local = raw[0]
        .parse::<Ipv4Addr>()
        .map_err(|_| invalid("ifconfig local address is not IPv4"))?;
    let second = raw[1].clone();
    let (netmask, peer, _topology) = match topology.unwrap_or(Topology::Net30) {
        Topology::Subnet => {
            let mask = second
                .parse::<Ipv4Addr>()
                .map_err(|_| invalid("ifconfig subnet netmask is not IPv4"))?;
            (mask, None, Topology::Subnet)
        }
        Topology::P2p => {
            let peer = second
                .parse::<Ipv4Addr>()
                .map_err(|_| invalid("ifconfig p2p peer is not IPv4"))?;
            (Ipv4Addr::new(255, 255, 255, 255), Some(peer), Topology::P2p)
        }
        Topology::Net30 => {
            let peer = second
                .parse::<Ipv4Addr>()
                .map_err(|_| invalid("ifconfig peer is not IPv4"))?;
            (
                Ipv4Addr::new(255, 255, 255, 252),
                Some(peer),
                Topology::Net30,
            )
        }
    };
    let prefix =
        mask_to_prefix(netmask).ok_or_else(|| invalid("ifconfig netmask is not contiguous"))?;
    let ifconfig = IfConfig {
        local,
        netmask,
        prefix,
        peer,
    };

    if redirect_default && !routes.iter().any(|route| route.is_default()) {
        routes.push(Route::new(Ipv4Addr::UNSPECIFIED, 0));
    }
    if gateway.is_none() {
        gateway = peer;
    }
    if redirect_default && gateway.is_none() {
        return Err(invalid(
            "redirect-gateway was pushed without a usable IPv4 gateway",
        ));
    }

    Ok(PushReply {
        ifconfig,
        gateway,
        routes,
        dns,
        cipher,
        peer_id,
        mtu,
        warnings,
        ping,
    })
}

impl fmt::Display for PushReply {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} /{} peer {:?} routes {} mtu {}",
            self.ifconfig.local,
            self.ifconfig.prefix,
            self.ifconfig.peer,
            self.routes.len(),
            self.mtu
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_subnet_profile_with_split_routes() {
        let push = parse_push_reply(
            "PUSH_REPLY,route-gateway 10.8.0.1,topology subnet,ifconfig 10.8.0.2 255.255.255.0,\
             peer-id 3,cipher AES-256-GCM,auth SHA256,dhcp-option DNS 10.8.0.1,\
             dhcp-option DOMAIN corp.example,route 192.168.50.0 255.255.255.0",
        )
        .unwrap();

        assert_eq!(push.ifconfig.local, Ipv4Addr::new(10, 8, 0, 2));
        assert_eq!(push.ifconfig.prefix, 24);
        assert_eq!(push.ifconfig.peer, None);
        assert_eq!(push.gateway, Some(Ipv4Addr::new(10, 8, 0, 1)));
        assert_eq!(push.cipher, Some(Cipher::Aes256Gcm));
        assert_eq!(push.peer_id, Some(3));
        assert_eq!(push.dns, vec![Ipv4Addr::new(10, 8, 0, 1)]);
        assert!(
            push.routes
                .iter()
                .any(|route| route.contains(Ipv4Addr::new(192, 168, 50, 20)))
        );
        assert!(push.ifconfig.is_on_link(Ipv4Addr::new(10, 8, 0, 9)));
        assert!(
            !push
                .routes
                .iter()
                .any(|route| route.contains(Ipv4Addr::new(192, 168, 60, 1)))
        );
        assert!(!push.has_default_route());
    }

    #[test]
    fn parses_net30_and_redirect_gateway() {
        let push = parse_push_reply(
            "PUSH_REPLY,ifconfig 10.8.0.6 10.8.0.5,route-gateway 10.8.0.5,\
             redirect-gateway def1,cipher AES-128-GCM,auth SHA1",
        )
        .unwrap();
        assert_eq!(push.ifconfig.prefix, 30);
        assert_eq!(push.ifconfig.peer, Some(Ipv4Addr::new(10, 8, 0, 5)));
        assert!(push.has_default_route());
        assert!(
            push.routes
                .iter()
                .any(|route| route.contains(Ipv4Addr::new(203, 0, 113, 9)))
        );
        assert_eq!(push.stack_gateway(), Some(Ipv4Addr::new(10, 8, 0, 5)));
    }

    #[test]
    fn honours_redirect_gateway_ipv4_flag() {
        let push = parse_push_reply("PUSH_REPLY,ifconfig 10.8.0.6 10.8.0.5,redirect-gateway !ipv4")
            .unwrap();
        assert!(!push.has_default_route());
    }

    #[test]
    fn rejects_compression_and_unsupported_ciphers() {
        let error =
            parse_push_reply("PUSH_REPLY,ifconfig 10.8.0.6 10.8.0.5,compress lz4-v2").unwrap_err();
        assert!(matches!(error, TunnelError::Unsupported(_)));

        let error = parse_push_reply("PUSH_REPLY,ifconfig 10.8.0.6 10.8.0.5,cipher AES-256-CBC")
            .unwrap_err();
        assert!(matches!(error, TunnelError::Unsupported(_)));
    }

    #[test]
    fn warns_about_ipv6_and_unknown_directives() {
        let push = parse_push_reply(
            "PUSH_REPLY,ifconfig 10.8.0.6 10.8.0.5,route-ipv6 fd00::/64,\
             dhcp-option DNS6 fd00::1,topology subnet,ifconfig 10.8.0.6 255.255.255.0,\
             something-new 1",
        );
        let push = push.unwrap();
        let warnings = push.warnings.join("\n");
        assert!(warnings.contains("IPv6"));
        assert!(warnings.contains("something-new"));
    }

    #[test]
    fn rejects_missing_or_malformed_ifconfig() {
        assert!(parse_push_reply("PUSH_REPLY,peer-id 0").is_err());
        assert!(parse_push_reply("PUSH_REPLY,ifconfig nonsense 10.8.0.5").is_err());
        assert!(parse_push_reply("PUSH_REPLY,ifconfig 10.8.0.6 10.8.0.5,topology subnet").is_err());
    }

    #[test]
    fn mask_conversion_is_contiguous_only() {
        assert_eq!(mask_to_prefix(Ipv4Addr::new(255, 255, 255, 0)), Some(24));
        assert_eq!(mask_to_prefix(Ipv4Addr::new(255, 255, 255, 252)), Some(30));
        assert_eq!(mask_to_prefix(Ipv4Addr::new(0, 0, 0, 0)), Some(0));
        assert_eq!(mask_to_prefix(Ipv4Addr::new(255, 0, 255, 0)), None);
    }
}

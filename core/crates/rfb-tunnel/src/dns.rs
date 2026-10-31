//! DNS over the tunnel, plus a system resolver fallback.
//!
//! Names are sent to the configured `DNS` servers through the smoltcp DNS
//! socket. When that is unavailable, times out or fails, the caller may fall
//! back to [`system_lookup`] (plain `getaddrinfo`), matching the design note:
//! without a tunnel DNS server the UI must be able to say that DNS does not go
//! through the tunnel.

use std::net::IpAddr;
use std::time::{Duration, Instant};

use smoltcp::iface::Context;
use smoltcp::socket::dns;
use smoltcp::wire::{DnsQueryType, IpAddress};

use crate::error::TunnelError;

/// How long one tunnel DNS query may take before it is cancelled.
pub(crate) const QUERY_TIMEOUT: Duration = Duration::from_secs(5);

/// A query in flight.
pub(crate) struct PendingQuery {
    /// The name being resolved, for error messages.
    pub host: String,
    handle: dns::QueryHandle,
    deadline: Instant,
}

/// Progress of [`poll_query`].
pub(crate) enum QueryProgress {
    /// Still waiting for the server.
    Pending,
    /// Resolved to one or more addresses.
    Done(Vec<IpAddr>),
    /// Failed or timed out; the caller may try a system lookup.
    Failed,
}

/// Creates a DNS socket for the given inner servers.
///
/// Servers that are not IPv4 addresses are skipped because this build of
/// `smoltcp` only compiles the IPv4 protocol.
pub(crate) fn new_socket(servers: &[IpAddr]) -> Option<dns::Socket<'static>> {
    let servers: Vec<IpAddress> = servers
        .iter()
        .filter_map(|ip| match ip {
            IpAddr::V4(ip) => Some(IpAddress::from(*ip)),
            IpAddr::V6(_) => None,
        })
        .collect();
    if servers.is_empty() {
        return None;
    }
    Some(dns::Socket::new(&servers, Vec::new()))
}

/// Starts an `A` query for `host`.
pub(crate) fn start_query(
    socket: &mut dns::Socket<'_>,
    context: &mut Context,
    host: &str,
    now: Instant,
) -> Result<PendingQuery, String> {
    let handle = socket
        .start_query(context, host, DnsQueryType::A)
        .map_err(|error| format!("could not start DNS query: {error}"))?;
    Ok(PendingQuery {
        host: host.to_string(),
        handle,
        deadline: now + QUERY_TIMEOUT,
    })
}

/// Checks a query and cancels it when its deadline has passed.
pub(crate) fn poll_query(
    socket: &mut dns::Socket<'_>,
    query: &PendingQuery,
    now: Instant,
) -> QueryProgress {
    match socket.get_query_result(query.handle) {
        Ok(addresses) => {
            let mut result = Vec::with_capacity(addresses.len());
            for address in addresses {
                result.push(IpAddr::from(address));
            }
            if result.is_empty() {
                QueryProgress::Failed
            } else {
                QueryProgress::Done(result)
            }
        }
        Err(dns::GetQueryResultError::Pending) => {
            if now >= query.deadline {
                socket.cancel_query(query.handle);
                QueryProgress::Failed
            } else {
                QueryProgress::Pending
            }
        }
        Err(dns::GetQueryResultError::Failed) => QueryProgress::Failed,
    }
}

/// Resolves `host` with the operating system resolver.
///
/// This is the explicit fallback for names that cannot be resolved through the
/// tunnel; callers decide whether such a fallback is acceptable.
pub async fn system_lookup(host: &str) -> Result<Vec<IpAddr>, TunnelError> {
    let host = host.trim();
    if host.is_empty() {
        return Err(TunnelError::Resolve {
            host: host.to_string(),
            detail: "empty host name".to_string(),
        });
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(vec![ip]);
    }

    let lookup = tokio::net::lookup_host((host, 0u16))
        .await
        .map_err(|error| TunnelError::Resolve {
            host: host.to_string(),
            detail: error.to_string(),
        })?;

    let mut addresses = Vec::new();
    for address in lookup {
        if !addresses.contains(&address.ip()) {
            addresses.push(address.ip());
        }
    }
    if addresses.is_empty() {
        return Err(TunnelError::Resolve {
            host: host.to_string(),
            detail: "the resolver returned no addresses".to_string(),
        });
    }
    Ok(addresses)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn system_lookup_passes_literals_through() {
        assert_eq!(
            system_lookup("10.66.66.1").await.unwrap(),
            vec![IpAddr::from([10, 66, 66, 1])]
        );
        assert_eq!(
            system_lookup("fd00::1").await.unwrap(),
            vec!["fd00::1".parse::<IpAddr>().unwrap()]
        );
    }

    #[tokio::test]
    async fn system_lookup_resolves_localhost() {
        let addresses = system_lookup("localhost").await.unwrap();
        assert!(addresses.iter().any(IpAddr::is_loopback));
    }

    #[tokio::test]
    async fn system_lookup_reports_empty_names() {
        assert!(system_lookup("  ").await.is_err());
    }

    #[test]
    fn ipv6_servers_are_skipped() {
        assert!(new_socket(&["fd00::1".parse().unwrap()]).is_none());
        assert!(new_socket(&[]).is_none());
        assert!(new_socket(&["10.66.66.1".parse().unwrap()]).is_some());
    }
}

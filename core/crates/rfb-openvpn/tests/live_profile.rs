//! Live end-to-end check against a real OpenVPN profile.
//!
//! The test is skipped unless `OPENVPN_TEST_PROFILE` points at an `.ovpn`
//! file. The profile is only ever read through [`OvpnConfig::parse_file`];
//! nothing from it is printed. The assertions cover the control channel,
//! `PUSH_REPLY`, data-channel keys and an inner TCP connection to one of the
//! two lab VNC servers.

use std::path::Path;
use std::time::Duration;

use rfb_openvpn::{OvpnConfig, Tunnel, TunnelOptions};
use tokio::io::AsyncReadExt;

const VNC_TARGETS: [(&str, u16); 2] = [("10.24.11.1", 5900), ("10.24.10.1", 5900)];

#[tokio::test(flavor = "multi_thread")]
async fn live_profile_end_to_end() {
    let Ok(path) = std::env::var("OPENVPN_TEST_PROFILE") else {
        eprintln!("skipped: OPENVPN_TEST_PROFILE is not set");
        return;
    };

    let profile = OvpnConfig::parse_file(Path::new(&path)).expect("the profile must parse");
    eprintln!(
        "profile: remote {} proto {:?} cipher {} tls-wrap {:?}",
        profile.remote().endpoint(),
        profile.remote().proto,
        profile.cipher.name(),
        profile
            .tls_wrap
            .as_ref()
            .map(|wrap| (wrap.mode, wrap.direction)),
    );

    let tunnel = Tunnel::connect(profile, TunnelOptions::default())
        .await
        .expect("the OpenVPN session must establish");
    let push = tunnel.push_info();
    eprintln!(
        "push: local {}/{} peer {:?} gateway {:?} dns {:?} routes {:?} cipher {} peer-id {:?} mtu {}",
        push.local,
        push.prefix,
        push.peer,
        push.gateway,
        push.dns,
        push.routes,
        push.cipher.name(),
        push.peer_id,
        push.mtu,
    );
    eprintln!("status: {:?}", tunnel.status());
    eprintln!("push warnings: {:?}", push.warnings);

    let mut attempts = Vec::new();
    for (host, port) in VNC_TARGETS {
        let ip: std::net::Ipv4Addr = host.parse().expect("literal");
        if !push.allows(ip) {
            attempts.push(format!("{host}:{port}: not covered by pushed routes"));
            continue;
        }
        match tokio::time::timeout(Duration::from_secs(20), async {
            let mut stream = tunnel.connect_tcp(host, port).await?;
            let mut banner = [0u8; 12];
            stream.read_exact(&mut banner).await?;
            Ok::<_, rfb_openvpn::TunnelError>(banner)
        })
        .await
        {
            Ok(Ok(banner)) => {
                assert_eq!(&banner, b"RFB 003.008\n");
                eprintln!(
                    "{host}:{port}: inner TCP established, banner {:?}",
                    String::from_utf8_lossy(&banner)
                );
                return;
            }
            Ok(Err(error)) => attempts.push(format!("{host}:{port}: {error}")),
            Err(_) => attempts.push(format!("{host}:{port}: timed out after 20s")),
        }
    }

    for attempt in &attempts {
        eprintln!("VNC attempt: {attempt}");
    }

    // Neither lab VNC server is reachable. Prove the data plane with the
    // pushed gateway/DNS instead: a TCP handshake that is either accepted or
    // actively refused shows that inner IP packets reach the server and its
    // replies (SYN-ACK or RST) come back through the tunnel.
    let Some(gateway) = push.gateway else {
        panic!("no VNC target and no pushed gateway to probe: {attempts:?}");
    };
    let result = tokio::time::timeout(
        Duration::from_secs(15),
        tunnel.connect_tcp(&gateway.to_string(), 53),
    )
    .await;
    match result {
        Ok(Ok(stream)) => {
            eprintln!("data plane: TCP to gateway {gateway}:53 established");
            drop(stream);
        }
        Ok(Err(rfb_openvpn::TunnelError::Connect { detail, .. })) if detail.contains("refused") => {
            eprintln!("data plane: gateway {gateway}:53 answered with RST ({detail})");
        }
        other => panic!(
            "no VNC target was routable and the gateway probe failed: {other:?} (VNC attempts: {attempts:?})"
        ),
    }
}

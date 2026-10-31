//! Live end-to-end check of the engine's OpenVPN stream.
//!
//! Skipped unless `OPENVPN_TEST_PROFILE` points at an `.ovpn` file. Optional
//! `OPENSCREENS_USERNAME` / `OPENSCREENS_PASSWORD` feed the RFB handshake.
//! Neither the profile nor the credentials are ever printed.

use std::time::Duration;

use rfb_engine::session::{Event, OpenVpnSettings, Session, SessionConfig};

const TARGETS: [(&str, u16); 2] = [("10.24.11.1", 5900), ("10.24.10.1", 5900)];

#[tokio::test(flavor = "multi_thread")]
async fn engine_connects_through_openvpn_tunnel() {
    let Ok(path) = std::env::var("OPENVPN_TEST_PROFILE") else {
        eprintln!("skipped: OPENVPN_TEST_PROFILE is not set");
        return;
    };
    let profile = std::fs::read_to_string(&path).expect("the profile must be readable");

    let mut failures = Vec::new();
    for (host, port) in TARGETS {
        let mut config = SessionConfig::new(host, port);
        config.username = std::env::var("OPENSCREENS_USERNAME").ok();
        config.password = std::env::var("OPENSCREENS_PASSWORD").ok();
        config.openvpn = Some(OpenVpnSettings {
            profile: profile.clone(),
            connect_timeout_secs: 20,
        });

        let outcome = tokio::time::timeout(Duration::from_secs(90), async {
            let session = Session::connect(config)
                .await
                .map_err(|error| error.to_string())?;
            loop {
                match session.next_event().await {
                    Some(Event::Connected { width, height, .. }) => return Ok((width, height)),
                    Some(_) => continue,
                    None => return Err("session ended before the desktop size arrived".to_owned()),
                }
            }
        })
        .await;

        match outcome {
            Ok(Ok((width, height))) => {
                eprintln!("{host}:{port}: connected through OpenVPN, desktop {width}x{height}");
                assert!(width > 0 && height > 0);
                return;
            }
            Ok(Err(error)) => failures.push(format!("{host}:{port}: {error}")),
            Err(_) => failures.push(format!("{host}:{port}: timed out after 90s")),
        }
    }
    panic!("no target accepted the tunnelled session: {failures:?}");
}

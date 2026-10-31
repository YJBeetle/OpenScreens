//! Control-channel TLS (rustls) and PEM loading.
//!
//! OpenVPN does not verify the server certificate host name by default; it
//! verifies the chain and, with `remote-cert-tls server`, the server EKU. This
//! module mirrors that: the chain is validated against the profile's CA, the
//! server EKU is always required, and the host name is deliberately not
//! checked. `verify-x509-name` is therefore reported as unsupported by the
//! parser.

use std::io::{BufReader, Read as _, Write as _};
use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::WebPkiSupportedAlgorithms;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{
    ClientConfig, ClientConnection, DigitallySignedStruct, RootCertStore, SignatureScheme,
};

use crate::config::{LoadedMaterial, OvpnConfig};
use crate::error::TunnelError;

/// Builds a rustls client configuration from the profile's PKI material.
pub(crate) fn build_client_config(
    profile: &OvpnConfig,
    material: &LoadedMaterial,
) -> Result<Arc<ClientConfig>, TunnelError> {
    let ca_certs = parse_certs(&material.ca_pem, "CA bundle")?;
    let mut roots = RootCertStore::empty();
    let (added, _ignored) = roots.add_parsable_certificates(ca_certs);
    if added == 0 {
        return Err(TunnelError::Tls(
            "the CA bundle contains no usable certificate".to_string(),
        ));
    }

    let cert_chain = parse_certs(&material.cert_pem, "client certificate")?;
    if cert_chain.is_empty() {
        return Err(TunnelError::Tls(
            "the client certificate file is empty".to_string(),
        ));
    }
    let key = parse_private_key(&material.key_pem)?;

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let algorithms = provider.signature_verification_algorithms;
    let verifier = Arc::new(OpenVpnServerVerifier { roots, algorithms });

    // `remote-cert-tls server` is the supported profile. The chain helper
    // always requires serverAuth EKU, which is what that option requests.
    let _requires_server_eku = profile.remote_cert_tls;
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| TunnelError::Tls(format!("TLS version setup failed: {error}")))?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(cert_chain, key)
        .map_err(|error| TunnelError::Tls(format!("client certificate is invalid: {error}")))?;
    Ok(Arc::new(config))
}

fn parse_certs(pem: &[u8], what: &str) -> Result<Vec<CertificateDer<'static>>, TunnelError> {
    let mut reader = BufReader::new(pem);
    let certs = rustls_pemfile::certs(&mut reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| TunnelError::Tls(format!("could not parse the {what}: {error}")))?;
    Ok(certs)
}

fn parse_private_key(pem: &[u8]) -> Result<PrivateKeyDer<'static>, TunnelError> {
    let mut reader = BufReader::new(pem);
    rustls_pemfile::private_key(&mut reader)
        .map_err(|error| TunnelError::Tls(format!("could not parse the private key: {error}")))?
        .ok_or_else(|| TunnelError::Tls("the private key file contains no key".to_string()))
}

/// A rustls server certificate verifier that skips the host-name check.
#[derive(Debug)]
struct OpenVpnServerVerifier {
    roots: RootCertStore,
    algorithms: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for OpenVpnServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let certificate = rustls::server::ParsedCertificate::try_from(end_entity)?;
        rustls::client::verify_server_cert_signed_by_trust_anchor(
            &certificate,
            &self.roots,
            intermediates,
            now,
            self.algorithms.all,
        )?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

/// A rustls client connection driven by OpenVPN control-channel packets.
pub(crate) struct TlsSession {
    connection: ClientConnection,
}

impl TlsSession {
    /// Creates a client session for `host` (used for SNI, not verification).
    pub(crate) fn new(config: Arc<ClientConfig>, host: &str) -> Result<Self, TunnelError> {
        let name = server_name(host)?;
        let connection = ClientConnection::new(config, name)
            .map_err(|error| TunnelError::Tls(format!("TLS client setup failed: {error}")))?;
        Ok(Self { connection })
    }

    pub(crate) fn is_handshaking(&self) -> bool {
        self.connection.is_handshaking()
    }

    /// The negotiated protocol version, once the handshake has finished.
    pub(crate) fn protocol_version(&self) -> Option<&'static str> {
        self.connection
            .protocol_version()
            .map(|version| match version {
                rustls::ProtocolVersion::TLSv1_2 => "TLSv1.2",
                rustls::ProtocolVersion::TLSv1_3 => "TLSv1.3",
                _ => "unknown",
            })
    }

    /// Feeds TLS ciphertext recovered from the control channel.
    pub(crate) fn read_tls(&mut self, data: &[u8]) -> Result<(), TunnelError> {
        if data.is_empty() {
            return Ok(());
        }
        let mut cursor = data;
        loop {
            let read = self
                .connection
                .read_tls(&mut cursor)
                .map_err(|error| TunnelError::Tls(format!("TLS read failed: {error}")))?;
            self.connection
                .process_new_packets()
                .map_err(|error| TunnelError::Tls(format!("TLS record rejected: {error}")))?;
            if read == 0 || cursor.is_empty() {
                break;
            }
        }
        Ok(())
    }

    /// Drains TLS ciphertext that must be queued on the control channel.
    pub(crate) fn take_ciphertext(&mut self) -> Result<Vec<u8>, TunnelError> {
        let mut output = Vec::new();
        let mut buffer = [0u8; 8192];
        loop {
            let mut writer: &mut [u8] = &mut buffer;
            let written = self
                .connection
                .write_tls(&mut writer)
                .map_err(|error| TunnelError::Tls(format!("TLS write failed: {error}")))?;
            if written == 0 {
                break;
            }
            output.extend_from_slice(&buffer[..written]);
            if output.len() > 1 << 20 {
                return Err(TunnelError::Tls(
                    "TLS produced an oversized control burst".to_string(),
                ));
            }
        }
        Ok(output)
    }

    /// Drains application data received over TLS.
    pub(crate) fn take_plaintext(&mut self) -> Result<Vec<u8>, TunnelError> {
        let mut output = Vec::new();
        let mut buffer = [0u8; 8192];
        loop {
            match self.connection.reader().read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => output.extend_from_slice(&buffer[..read]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => {
                    return Err(TunnelError::Tls(format!(
                        "TLS plaintext read failed: {error}"
                    )));
                }
            }
        }
        Ok(output)
    }

    /// Writes application data (key method, PUSH_REQUEST).
    pub(crate) fn write_plaintext(&mut self, data: &[u8]) -> Result<(), TunnelError> {
        self.connection
            .writer()
            .write_all(data)
            .map_err(|error| TunnelError::Tls(format!("TLS plaintext write failed: {error}")))
    }
}

fn server_name(host: &str) -> Result<ServerName<'static>, TunnelError> {
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return Ok(ServerName::IpAddress(ip.into()));
    }
    ServerName::try_from(host.to_string())
        .map_err(|_| TunnelError::Tls("the remote host is not a valid TLS server name".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::{ServerConfig, ServerConnection};

    const CA: &[u8] = include_bytes!("../tests/data/ca.crt");
    const CLIENT_CERT: &[u8] = include_bytes!("../tests/data/client.crt");
    const CLIENT_KEY: &[u8] = include_bytes!("../tests/data/client.key");
    const SERVER_CERT: &[u8] = include_bytes!("../tests/data/server.crt");
    const SERVER_KEY: &[u8] = include_bytes!("../tests/data/server.key");
    const OTHER_CA: &[u8] = include_bytes!("../tests/data/other-ca.crt");

    fn profile(ca: &[u8]) -> OvpnConfig {
        let ca = String::from_utf8(ca.to_vec()).unwrap();
        let cert = String::from_utf8(CLIENT_CERT.to_vec()).unwrap();
        let key = String::from_utf8(CLIENT_KEY.to_vec()).unwrap();
        let text = format!(
            "client\ndev tun\nremote vpn.test 1194\n<ca>\n{ca}</ca>\n<cert>\n{cert}</cert>\n<key>\n{key}</key>\nremote-cert-tls server\n"
        );
        OvpnConfig::parse(&text).unwrap()
    }

    fn client_tls(host: &str) -> TlsSession {
        let profile = profile(CA);
        let material = profile.load_material().unwrap();
        let config = build_client_config(&profile, &material).unwrap();
        TlsSession::new(config, host).unwrap()
    }

    fn server_config() -> Arc<ServerConfig> {
        let certs = parse_certs(SERVER_CERT, "server certificate").unwrap();
        let key = parse_private_key(SERVER_KEY).unwrap();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        Arc::new(
            ServerConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(certs, key)
                .unwrap(),
        )
    }

    fn pump(client: &mut TlsSession, server: &mut ServerConnection) -> Result<(), TunnelError> {
        let c2s = client.take_ciphertext()?;
        if !c2s.is_empty() {
            server
                .read_tls(&mut c2s.as_slice())
                .map_err(|error| TunnelError::Tls(format!("server read failed: {error}")))?;
            server
                .process_new_packets()
                .map_err(|error| TunnelError::Tls(format!("server rejected a record: {error}")))?;
        }
        let mut s2c = Vec::new();
        let mut buffer = [0u8; 8192];
        loop {
            let mut writer: &mut [u8] = &mut buffer;
            let written = server
                .write_tls(&mut writer)
                .map_err(|error| TunnelError::Tls(format!("server write failed: {error}")))?;
            if written == 0 {
                break;
            }
            s2c.extend_from_slice(&buffer[..written]);
        }
        if !s2c.is_empty() {
            client.read_tls(&s2c)?;
        }
        Ok(())
    }

    #[test]
    fn completes_a_real_tls_handshake_and_exchanges_app_data() {
        let mut client = client_tls("vpn.test");
        let mut server = ServerConnection::new(server_config()).unwrap();

        for _ in 0..32 {
            pump(&mut client, &mut server).unwrap();
            if !client.is_handshaking() && !server.is_handshaking() {
                break;
            }
        }
        assert!(!client.is_handshaking(), "client handshake must finish");
        assert!(!server.is_handshaking(), "server handshake must finish");

        client.write_plaintext(b"PUSH_REQUEST\0").unwrap();
        pump(&mut client, &mut server).unwrap();
        let mut request = [0u8; 32];
        let read = server.reader().read(&mut request).unwrap();
        assert_eq!(&request[..read], b"PUSH_REQUEST\0");

        server
            .writer()
            .write_all(b"PUSH_REPLY,ifconfig 10.8.0.6 10.8.0.5\0")
            .unwrap();
        pump(&mut client, &mut server).unwrap();
        let reply = client.take_plaintext().unwrap();
        assert!(reply.starts_with(b"PUSH_REPLY,"));
    }

    #[test]
    fn skips_host_name_verification_like_openvpn() {
        // The certificate is for vpn.test, but OpenVPN connects by address and
        // does not check the name unless verify-x509-name is set.
        let mut client = client_tls("203.0.113.7");
        let mut server = ServerConnection::new(server_config()).unwrap();
        for _ in 0..32 {
            pump(&mut client, &mut server).unwrap();
            if !client.is_handshaking() && !server.is_handshaking() {
                break;
            }
        }
        assert!(!client.is_handshaking());
    }

    #[test]
    fn rejects_an_untrusted_ca() {
        let profile = profile(OTHER_CA);
        let material = profile.load_material().unwrap();
        let config = build_client_config(&profile, &material).unwrap();
        let mut client = TlsSession::new(config, "vpn.test").unwrap();
        let mut server = ServerConnection::new(server_config()).unwrap();
        let mut failed = false;
        for _ in 0..32 {
            if pump(&mut client, &mut server).is_err() {
                failed = true;
                break;
            }
            if !client.is_handshaking() && !server.is_handshaking() {
                break;
            }
        }
        assert!(failed || client.is_handshaking());
    }

    #[test]
    fn rejects_missing_client_certificate_material() {
        let text =
            "client\ndev tun\nremote vpn.test 1194\n<ca>\n</ca>\n<cert>\n</cert>\n<key>\n</key>\n";
        assert!(OvpnConfig::parse(text).is_err());
    }
}

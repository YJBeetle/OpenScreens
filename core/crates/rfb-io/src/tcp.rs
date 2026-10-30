//! TCP transport.

use std::io;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;

pub trait Transport: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Transport for T {}

pub type BoxedTransport = Box<dyn Transport>;

/// Connects to an RFB server over TCP.
pub async fn connect_tcp(host: &str, port: u16) -> io::Result<TcpStream> {
    let stream = TcpStream::connect((host, port)).await?;
    stream.set_nodelay(true)?;
    Ok(stream)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn connects_to_local_listener() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            socket.write_all(b"ok").await.unwrap();
        });

        let mut client = connect_tcp("127.0.0.1", address.port()).await.unwrap();
        let mut reply = [0u8; 2];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply, b"ok");
        server.await.unwrap();
    }
}

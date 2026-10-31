//! `OpenVpnStream`: an `AsyncRead + AsyncWrite` byte stream over one smoltcp
//! TCP connection inside the OpenVPN tunnel.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{mpsc, oneshot, watch};

use crate::tunnel::{Command, TunnelHandle};

pub(crate) const WRITE_CHUNK: usize = 32 * 1024;

/// Stores the waker of a blocked writer so the driver can wake it.
#[derive(Default)]
pub(crate) struct ConnWake {
    slot: Mutex<Option<Waker>>,
}

impl ConnWake {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn register(&self, waker: &Waker) {
        let mut slot = self
            .slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match slot.as_ref() {
            Some(existing) if existing.will_wake(waker) => {}
            _ => *slot = Some(waker.clone()),
        }
    }

    pub(crate) fn wake(&self) {
        let waker = self
            .slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}

/// Per-connection state, also observed by [`OpenVpnStream`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ConnState {
    Connecting,
    Established,
    Closed,
    Failed(String),
}

/// The half of a connection handed from the driver to the stream.
pub(crate) struct StreamParts {
    pub(crate) rx: mpsc::Receiver<Vec<u8>>,
    pub(crate) tx: mpsc::Sender<Vec<u8>>,
    pub(crate) state: watch::Receiver<ConnState>,
    pub(crate) wake: Arc<ConnWake>,
}

/// A TCP connection through the OpenVPN tunnel.
pub struct OpenVpnStream {
    handle: Arc<TunnelHandle>,
    id: u32,
    rx: mpsc::Receiver<Vec<u8>>,
    tx: mpsc::Sender<Vec<u8>>,
    state: watch::Receiver<ConnState>,
    wake: Arc<ConnWake>,
    read_buffer: Vec<u8>,
    read_offset: usize,
    shutdown_ack: Option<oneshot::Receiver<()>>,
    shutdown_sent: bool,
    shutdown_done: bool,
}

impl OpenVpnStream {
    pub(crate) fn new(handle: Arc<TunnelHandle>, id: u32, parts: StreamParts) -> Self {
        Self {
            handle,
            id,
            rx: parts.rx,
            tx: parts.tx,
            state: parts.state,
            wake: parts.wake,
            read_buffer: Vec::new(),
            read_offset: 0,
            shutdown_ack: None,
            shutdown_sent: false,
            shutdown_done: false,
        }
    }

    fn failed(&self) -> Option<io::Error> {
        match &*self.state.borrow() {
            ConnState::Failed(message) => Some(io::Error::new(
                io::ErrorKind::ConnectionReset,
                message.clone(),
            )),
            ConnState::Closed => Some(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "connection is closed",
            )),
            ConnState::Connecting | ConnState::Established => None,
        }
    }
}

impl std::fmt::Debug for OpenVpnStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenVpnStream")
            .field("id", &self.id)
            .field("state", &*self.state.borrow())
            .finish()
    }
}

impl AsyncRead for OpenVpnStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if buf.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        loop {
            if this.read_offset < this.read_buffer.len() {
                let available = this.read_buffer.len() - this.read_offset;
                let count = available.min(buf.remaining());
                buf.put_slice(&this.read_buffer[this.read_offset..this.read_offset + count]);
                this.read_offset += count;
                if this.read_offset == this.read_buffer.len() {
                    this.read_buffer.clear();
                    this.read_offset = 0;
                }
                return Poll::Ready(Ok(()));
            }
            match this.rx.poll_recv(cx) {
                Poll::Ready(Some(chunk)) => {
                    if chunk.is_empty() {
                        continue;
                    }
                    this.read_buffer = chunk;
                    this.read_offset = 0;
                }
                Poll::Ready(None) => {
                    return Poll::Ready(match &*this.state.borrow() {
                        ConnState::Failed(message) => Err(io::Error::new(
                            io::ErrorKind::ConnectionReset,
                            message.clone(),
                        )),
                        _ => Ok(()),
                    });
                }
                Poll::Pending => return Poll::Pending,
            }
        }
    }
}

impl AsyncWrite for OpenVpnStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        if buf.is_empty() {
            return Poll::Ready(Ok(0));
        }
        if this.shutdown_sent || this.shutdown_done {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "stream was shut down",
            )));
        }
        if let Some(error) = this.failed() {
            return Poll::Ready(Err(error));
        }

        let length = buf.len().min(WRITE_CHUNK);
        match this.tx.try_reserve() {
            Ok(permit) => {
                permit.send(buf[..length].to_vec());
                this.handle.notify.notify_one();
                Poll::Ready(Ok(length))
            }
            Err(mpsc::error::TrySendError::Full(())) => {
                this.wake.register(cx.waker());
                Poll::Pending
            }
            Err(mpsc::error::TrySendError::Closed(())) => Poll::Ready(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "connection is closed",
            ))),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        match this.failed() {
            Some(error) => Poll::Ready(Err(error)),
            None => Poll::Ready(Ok(())),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if this.shutdown_done {
            return Poll::Ready(Ok(()));
        }
        if !this.shutdown_sent {
            match &*this.state.borrow() {
                ConnState::Closed => {
                    this.shutdown_done = true;
                    return Poll::Ready(Ok(()));
                }
                ConnState::Failed(message) => {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::ConnectionReset,
                        message.clone(),
                    )));
                }
                ConnState::Connecting | ConnState::Established => {}
            }
            let (ack, receiver) = oneshot::channel();
            match this.handle.commands.send(Command::Close {
                id: this.id,
                ack: Some(ack),
            }) {
                Ok(()) => {
                    this.shutdown_sent = true;
                    this.shutdown_ack = Some(receiver);
                }
                Err(_) => {
                    this.shutdown_done = true;
                    return Poll::Ready(Ok(()));
                }
            }
        }
        let Some(ack) = this.shutdown_ack.as_mut() else {
            return Poll::Ready(Ok(()));
        };
        match Pin::new(ack).poll(cx) {
            Poll::Ready(Ok(())) | Poll::Ready(Err(_)) => {
                this.shutdown_done = true;
                Poll::Ready(Ok(()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_is_a_transport() {
        use tokio::io::{AsyncRead, AsyncWrite};
        fn assert_transport<T: AsyncRead + AsyncWrite + Unpin + Send>() {}
        assert_transport::<OpenVpnStream>();
    }

    #[test]
    fn wake_holds_one_waker() {
        let wake = ConnWake::new();
        // No waker registered: waking is a no-op.
        wake.wake();
        assert!(wake.slot.lock().unwrap().is_none());
    }
}

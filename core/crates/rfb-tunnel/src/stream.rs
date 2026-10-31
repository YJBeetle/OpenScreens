//! `TunnelStream`: an `AsyncRead + AsyncWrite` byte stream over one smoltcp TCP
//! connection.
//!
//! Both directions are bounded:
//!
//! * app → driver: a bounded channel of at most [`WRITE_CHUNK`] sized chunks;
//!   a full channel makes `poll_write` return `Pending` after registering a
//!   waker that the driver fires once it consumed a chunk.
//! * driver → app: a bounded channel; the driver only takes bytes off the
//!   smoltcp socket when there is room, so the TCP receive window shrinks and
//!   backpressure reaches the peer instead of growing an unbounded queue.
//!
//! Shutdown is two-phase: the driver drains everything the app wrote into the
//! smoltcp send buffer and only then sends FIN.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{mpsc, oneshot, watch};

use crate::stack::{Command, ConnState, TunnelHandle};

/// Largest chunk accepted by one `poll_write` call.
///
/// A caller with a bigger buffer gets a short write and is expected to retry,
/// which keeps the per-stream queue memory bounded.
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

/// The half of a connection handed from the driver to the stream.
pub(crate) struct StreamParts {
    pub rx: mpsc::Receiver<Vec<u8>>,
    pub tx: mpsc::Sender<Vec<u8>>,
    pub state: watch::Receiver<ConnState>,
    pub wake: Arc<ConnWake>,
}

/// A TCP connection through the tunnel.
///
/// Holding the stream keeps the tunnel driver alive even if the [`crate::Tunnel`]
/// handle itself is dropped; the driver exits when the last stream is dropped
/// or when [`crate::Tunnel::stop`] is called.
pub struct TunnelStream {
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

impl TunnelStream {
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

impl std::fmt::Debug for TunnelStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TunnelStream")
            .field("id", &self.id)
            .field("state", &*self.state.borrow())
            .finish()
    }
}

impl AsyncRead for TunnelStream {
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

impl AsyncWrite for TunnelStream {
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
            let command = Command::Close {
                id: this.id,
                ack: Some(ack),
            };
            match this.handle.commands.send(command) {
                Ok(()) => {
                    this.shutdown_sent = true;
                    this.shutdown_ack = Some(receiver);
                }
                Err(_) => {
                    // The driver is gone; there is nothing left to flush.
                    this.shutdown_done = true;
                    return Poll::Ready(Ok(()));
                }
            }
        }

        let Some(ack) = this.shutdown_ack.as_mut() else {
            return Poll::Ready(Ok(()));
        };
        match Pin::new(ack).poll(cx) {
            Poll::Ready(Ok(())) => {
                this.shutdown_done = true;
                Poll::Ready(Ok(()))
            }
            // The driver disappeared before acknowledging: the connection is
            // dead, but shutdown has nothing left to do.
            Poll::Ready(Err(_)) => {
                this.shutdown_done = true;
                Poll::Ready(Ok(()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

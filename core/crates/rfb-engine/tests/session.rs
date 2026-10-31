use std::time::Duration;

use rfb_codec::Rect;
use rfb_engine::session::{DisplayScreen, Event, Session, SessionConfig};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream, duplex};
use tokio::time::timeout;

const WIDTH: u16 = 2;
const HEIGHT: u16 = 2;

fn server_init() -> Vec<u8> {
    let mut message = Vec::new();
    message.extend_from_slice(&WIDTH.to_be_bytes());
    message.extend_from_slice(&HEIGHT.to_be_bytes());
    message.extend_from_slice(&rfb_proto::pixel_format::PixelFormat::bgra8888().encode());
    message.extend_from_slice(&4u32.to_be_bytes());
    message.extend_from_slice(b"Mock");
    message
}

async fn perform_handshake(server: &mut DuplexStream) {
    server.write_all(b"RFB 003.008\n").await.unwrap();
    let mut version = [0u8; 12];
    server.read_exact(&mut version).await.unwrap();
    assert_eq!(&version, b"RFB 003.008\n");

    server.write_all(&[1, 1]).await.unwrap();
    let mut security = [0u8; 1];
    server.read_exact(&mut security).await.unwrap();
    assert_eq!(security[0], 1);

    server.write_all(&0u32.to_be_bytes()).await.unwrap();
    let mut client_init = [0u8; 1];
    server.read_exact(&mut client_init).await.unwrap();
    assert_eq!(client_init[0], 1);

    server.write_all(&server_init()).await.unwrap();
}

async fn read_setup(server: &mut DuplexStream) -> Vec<i32> {
    let mut set_pixel_format = [0u8; 20];
    server.read_exact(&mut set_pixel_format).await.unwrap();
    assert_eq!(set_pixel_format[0], 0);

    let mut set_encodings = [0u8; 4];
    server.read_exact(&mut set_encodings).await.unwrap();
    assert_eq!(set_encodings[0], 2);
    let count = u16::from_be_bytes([set_encodings[2], set_encodings[3]]);
    let mut raw = vec![0u8; usize::from(count) * 4];
    server.read_exact(&mut raw).await.unwrap();
    let encodings = raw
        .chunks_exact(4)
        .map(|id| i32::from_be_bytes([id[0], id[1], id[2], id[3]]))
        .collect();

    let mut request = [0u8; 10];
    server.read_exact(&mut request).await.unwrap();
    assert_eq!(request[0], 3);
    assert_eq!(request[1], 0);
    encodings
}

fn raw_update() -> Vec<u8> {
    let mut update = Vec::new();
    update.push(0);
    update.push(0);
    update.extend_from_slice(&1u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&WIDTH.to_be_bytes());
    update.extend_from_slice(&HEIGHT.to_be_bytes());
    update.extend_from_slice(&0i32.to_be_bytes());
    update.extend_from_slice(&[
        0, 0, 255, 255, // red
        0, 255, 0, 255, // green
        255, 0, 0, 255, // blue
        255, 255, 255, 255, // white
    ]);
    update
}

fn desktop_layout_message(
    declared_screens: u8,
    width: u16,
    height: u16,
    screens: &[(u32, u16, u16, u16, u16, u32)],
) -> Vec<u8> {
    let mut update = Vec::new();
    update.push(0);
    update.push(0);
    update.extend_from_slice(&1u16.to_be_bytes());
    // For -308 the rect header x and y fields carry the new framebuffer size.
    update.extend_from_slice(&width.to_be_bytes());
    update.extend_from_slice(&height.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&(-308i32).to_be_bytes());
    update.push(declared_screens);
    update.push(0); // server-side resize reason
    for &(id, x, y, w, h, flags) in screens {
        update.extend_from_slice(&id.to_be_bytes());
        update.extend_from_slice(&x.to_be_bytes());
        update.extend_from_slice(&y.to_be_bytes());
        update.extend_from_slice(&w.to_be_bytes());
        update.extend_from_slice(&h.to_be_bytes());
        update.extend_from_slice(&flags.to_be_bytes());
    }
    update
}

fn cursor_update() -> Vec<u8> {
    let mut update = Vec::new();
    update.push(0);
    update.push(0);
    update.extend_from_slice(&2u16.to_be_bytes());

    // Cursor pseudo-rect: 2x2 bitmap with hotspot (1, 1).
    update.extend_from_slice(&1u16.to_be_bytes());
    update.extend_from_slice(&1u16.to_be_bytes());
    update.extend_from_slice(&2u16.to_be_bytes());
    update.extend_from_slice(&2u16.to_be_bytes());
    update.extend_from_slice(&(-239i32).to_be_bytes());
    update.extend_from_slice(&[
        0, 0, 255, 255, // red
        0, 0, 255, 255, // red
        0, 0, 255, 255, // red
        0, 0, 255, 255, // red
    ]);
    update.extend_from_slice(&[0b1100_0000, 0b1100_0000]);

    // PointerPos pseudo-rect at (5, 6).
    update.extend_from_slice(&5u16.to_be_bytes());
    update.extend_from_slice(&6u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&(-232i32).to_be_bytes());
    update.extend_from_slice(&[0, 5, 0, 6]);
    update
}

#[tokio::test]
async fn local_cursor_events() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        let encodings = read_setup(&mut server).await;
        assert_eq!(encodings.len(), 12);
        assert!(encodings.contains(&(-239)));

        server.write_all(&cursor_update()).await.unwrap();

        let mut request = [0u8; 10];
        server.read_exact(&mut request).await.unwrap();
        assert_eq!(request[0], 3);
        assert_eq!(request[1], 1);
    });

    let mut config = SessionConfig::new("mock", 5900);
    config.local_cursor = true;
    let session = Session::connect_stream(client, config).await.unwrap();

    let connected = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    let cursor = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    match cursor {
        Event::Cursor(shape) => {
            assert_eq!((shape.hotspot_x, shape.hotspot_y), (1, 1));
            assert_eq!((shape.width, shape.height), (2, 2));
            assert_eq!(shape.pixels.len(), 2 * 2 * 4);
            assert_eq!(shape.pixels[3], 255);
            assert_eq!(shape.pixels[4 * 2 + 3], 255);
        }
        other => panic!("expected cursor, got {other:?}"),
    }

    let position = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(position, Event::PointerPosition { x: 5, y: 6 });

    let disconnected = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(disconnected, Event::Disconnected { .. }));

    server_task.await.unwrap();
}

#[tokio::test]
async fn extended_desktop_size_resizes_framebuffer() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        let encodings = read_setup(&mut server).await;
        assert!(
            encodings.contains(&(-308)),
            "ExtendedDesktopSize not advertised: {encodings:?}"
        );

        server
            .write_all(&desktop_layout_message(
                2,
                4,
                3,
                &[(7, 0, 0, 3, 3, 0), (9, 3, 0, 1, 3, 1)],
            ))
            .await
            .unwrap();

        // The next incremental request covers the new framebuffer size.
        let mut request = [0u8; 10];
        server.read_exact(&mut request).await.unwrap();
        assert_eq!(request, [3, 1, 0, 0, 0, 0, 0, 4, 0, 3]);
    });

    let session = Session::connect_stream(client, SessionConfig::new("mock", 5900))
        .await
        .unwrap();

    let connected = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    let layout = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    match layout {
        Event::DesktopLayout {
            width,
            height,
            screens,
        } => {
            assert_eq!((width, height), (4, 3));
            assert_eq!(
                screens,
                vec![
                    DisplayScreen {
                        id: 7,
                        x: 0,
                        y: 0,
                        width: 3,
                        height: 3,
                        flags: 0
                    },
                    DisplayScreen {
                        id: 9,
                        x: 3,
                        y: 0,
                        width: 1,
                        height: 3,
                        flags: 1
                    },
                ]
            );
        }
        other => panic!("expected desktop layout, got {other:?}"),
    }

    assert_eq!(session.size(), Some((4, 3)));
    server_task.await.unwrap();
}

#[tokio::test]
async fn truncated_desktop_layout_payload_disconnects() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        read_setup(&mut server).await;

        // Declares two screens but only one 16-byte entry follows; closing the
        // server half then truncates the payload mid-message.
        let update = desktop_layout_message(2, 4, 3, &[(7, 0, 0, 3, 3, 0)]);
        server.write_all(&update).await.unwrap();
    });

    let session = Session::connect_stream(client, SessionConfig::new("mock", 5900))
        .await
        .unwrap();

    let connected = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    let disconnected = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(
        matches!(disconnected, Event::Disconnected { .. }),
        "expected disconnect, got {disconnected:?}"
    );

    // A malformed payload must not resize the framebuffer.
    assert_eq!(session.size(), Some((WIDTH, HEIGHT)));
    server_task.await.unwrap();
}

#[tokio::test]
async fn viewport_limits_update_requests() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        read_setup(&mut server).await;

        // Changing the viewport requests the region immediately.
        let mut first = [0u8; 10];
        server.read_exact(&mut first).await.unwrap();
        assert_eq!(first, [3, 0, 0, 1, 0, 1, 0, 1, 0, 1]);

        server.write_all(&raw_update()).await.unwrap();
        let mut next = [0u8; 10];
        server.read_exact(&mut next).await.unwrap();
        assert_eq!(next, [3, 1, 0, 1, 0, 1, 0, 1, 0, 1]);
    });

    let session = Session::connect_stream(client, SessionConfig::new("mock", 5900))
        .await
        .unwrap();
    session
        .set_viewport(Some(Rect {
            x: 1,
            y: 1,
            width: 1,
            height: 1,
        }))
        .await
        .unwrap();
    server_task.await.unwrap();
    drop(session);
}

#[tokio::test]
async fn advertises_configured_quality() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        read_setup(&mut server).await
    });

    let mut config = SessionConfig::new("mock", 5900);
    config.quality = 4;
    let session = Session::connect_stream(client, config).await.unwrap();
    let encodings = server_task.await.unwrap();

    assert!(encodings.contains(&-28), "got {encodings:?}");
    drop(session);
}

#[tokio::test]
async fn paces_incremental_requests() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        read_setup(&mut server).await;

        server.write_all(&raw_update()).await.unwrap();
        let mut request = [0u8; 10];
        server.read_exact(&mut request).await.unwrap();

        let sent = std::time::Instant::now();
        server.write_all(&raw_update()).await.unwrap();
        server.read_exact(&mut request).await.unwrap();
        sent.elapsed()
    });

    let mut config = SessionConfig::new("mock", 5900);
    config.frame_interval_ms = 100;
    let session = Session::connect_stream(client, config).await.unwrap();

    let gap = server_task.await.unwrap();
    assert!(
        gap >= Duration::from_millis(60),
        "second request came after {gap:?}"
    );
    drop(session);
}

#[tokio::test]
async fn session_round_trip() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        let encodings = read_setup(&mut server).await;
        assert!(!encodings.is_empty());

        let mut pointer = [0u8; 6];
        server.read_exact(&mut pointer).await.unwrap();
        assert_eq!(pointer, [5, 1, 0, 10, 0, 20]);

        let mut key = [0u8; 8];
        server.read_exact(&mut key).await.unwrap();
        assert_eq!(key, [4, 1, 0, 0, 0, 0, 0, 0x61]);

        let mut cut = [0u8; 8];
        server.read_exact(&mut cut).await.unwrap();
        assert_eq!(cut[0], 6);
        let cut_len = u32::from_be_bytes([cut[4], cut[5], cut[6], cut[7]]);
        let mut text = vec![0u8; cut_len as usize];
        server.read_exact(&mut text).await.unwrap();
        assert_eq!(text, b"hey");

        server.write_all(&raw_update()).await.unwrap();

        let mut request = [0u8; 10];
        server.read_exact(&mut request).await.unwrap();
        assert_eq!(request[0], 3);
        assert_eq!(request[1], 1);

        server
            .write_all(&[3, 0, 0, 0, 0, 0, 0, 2, b'h', b'i'])
            .await
            .unwrap();
        server.write_all(&[2]).await.unwrap();
    });

    let session = Session::connect_stream(client, SessionConfig::new("mock", 5900))
        .await
        .unwrap();
    session.send_pointer(1, 10, 20).await.unwrap();
    session.send_key(true, 0x61).await.unwrap();
    session.send_clipboard("hey").await.unwrap();

    let mut events = Vec::new();
    for _ in 0..5 {
        let event = timeout(Duration::from_secs(2), session.next_event())
            .await
            .unwrap()
            .unwrap();
        events.push(event);
    }

    assert!(matches!(
        events[0],
        Event::Connected {
            width: 2,
            height: 2,
            ..
        }
    ));
    match &events[1] {
        Event::Frame { rects, .. } => {
            assert_eq!(
                rects,
                &[Rect {
                    x: 0,
                    y: 0,
                    width: 2,
                    height: 2
                }]
            );
        }
        other => panic!("expected frame, got {other:?}"),
    }
    assert_eq!(
        events[2],
        Event::Clipboard {
            text: "hi".to_owned()
        }
    );
    assert_eq!(events[3], Event::Bell);
    assert!(matches!(events[4], Event::Disconnected { .. }));

    let pixels = session
        .copy_region(Rect {
            x: 0,
            y: 0,
            width: 2,
            height: 2,
        })
        .unwrap();
    assert_eq!(
        pixels,
        vec![
            0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255
        ]
    );

    server_task.await.unwrap();
}

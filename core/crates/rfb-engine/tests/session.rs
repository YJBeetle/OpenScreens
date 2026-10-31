use std::time::Duration;

use rfb_codec::Rect;
use rfb_engine::session::{Event, Session, SessionConfig};
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

async fn read_setup(server: &mut DuplexStream) -> u16 {
    let mut set_pixel_format = [0u8; 20];
    server.read_exact(&mut set_pixel_format).await.unwrap();
    assert_eq!(set_pixel_format[0], 0);

    let mut set_encodings = [0u8; 4];
    server.read_exact(&mut set_encodings).await.unwrap();
    assert_eq!(set_encodings[0], 2);
    let count = u16::from_be_bytes([set_encodings[2], set_encodings[3]]);
    let mut encodings = vec![0u8; usize::from(count) * 4];
    server.read_exact(&mut encodings).await.unwrap();

    let mut request = [0u8; 10];
    server.read_exact(&mut request).await.unwrap();
    assert_eq!(request[0], 3);
    assert_eq!(request[1], 0);
    count
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
        let encoding_count = read_setup(&mut server).await;
        assert_eq!(encoding_count, 11);

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
async fn session_round_trip() {
    let (client, mut server) = duplex(64 * 1024);

    let server_task = tokio::spawn(async move {
        perform_handshake(&mut server).await;
        let encoding_count = read_setup(&mut server).await;
        assert!(encoding_count > 0);

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

use std::time::Duration;

use rfb_codec::Rect;
use rfb_engine::apple_file_transfer as ft;
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
        .as_chunks::<4>()
        .0
        .iter()
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
    update.extend_from_slice(&[0, 0, 0]); // padding before the screen records
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
        perform_apple_handshake(&mut server).await;
        let encodings = read_setup(&mut server).await;
        assert!(encodings.contains(&(-239)));

        server.write_all(&cursor_update()).await.unwrap();

        let mut request = [0u8; 10];
        server.read_exact(&mut request).await.unwrap();
        assert_eq!(request[0], 3);
        assert_eq!(request[1], 1);
    });

    let mut config = SessionConfig::new("mock", 5900);
    config.apple_session = true;
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

#[tokio::test]
async fn apple_file_transfer_events() {
    let (client, mut server) = duplex(64 * 1024);
    let task = tokio::spawn(async move {
        Session::connect_stream(client, SessionConfig::new("mock", 5900))
            .await
            .unwrap()
    });
    perform_handshake(&mut server).await;
    let _ = read_setup(&mut server).await;
    let session = task.await.unwrap();
    let connected = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    let path = "/Users/example/Desktop";
    let mut request = vec![0x1e, 0, 0, 0];
    request.extend_from_slice(&0x1242_fe7eu32.to_be_bytes());
    request.extend_from_slice(&(path.len() as u32).to_be_bytes());
    request.extend_from_slice(path.as_bytes());
    server.write_all(&request).await.unwrap();

    let urls = ["file:///Users/example/Desktop/a.txt"];
    server
        .write_all(&ft::drag_in_message(0x1242_fe7e, &urls))
        .await
        .unwrap();

    let mut payload = Vec::new();
    payload.extend_from_slice(&5u32.to_be_bytes());
    payload.extend_from_slice(b"a.txt");
    let container = ft::Container {
        subtype: ft::SUBTYPE_PROGRESS,
        handle: 3,
        payload: payload.clone(),
    };
    server.write_all(&container.encode()).await.unwrap();

    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        event,
        Event::UploadRequest {
            handle: 0x1242_fe7e,
            path: path.to_string()
        }
    );
    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        event,
        Event::DragInfo {
            handle: 0x1242_fe7e,
            pasteboard: ft::pasteboard_file_urls(&urls)
        }
    );
    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        event,
        Event::FileTransfer {
            subtype: ft::SUBTYPE_PROGRESS,
            handle: 3,
            payload
        }
    );
}

#[tokio::test]
async fn client_sends_file_transfer_messages() {
    let (client, mut server) = duplex(64 * 1024);
    let task = tokio::spawn(async move {
        Session::connect_stream(client, SessionConfig::new("mock", 5900))
            .await
            .unwrap()
    });
    perform_handshake(&mut server).await;
    let _ = read_setup(&mut server).await;
    let session = task.await.unwrap();

    assert_eq!(session.next_transfer_handle(), 1);
    assert_eq!(session.next_transfer_handle(), 2);

    let url = "file:///tmp/a.txt";
    session
        .announce_upload(1, &[url.to_string()])
        .await
        .unwrap();
    session
        .upload_destination(1, "/Users/example/Desktop")
        .await
        .unwrap();
    session.upload_summary(1, 1600, 1, 0).await.unwrap();
    let entry = ft::Entry {
        kind: ft::EntryKind::File,
        name: "a.txt",
        data_size: 1600,
        resource_size: 0,
        mode: 0o100_644,
        nesting: 0,
        created: ft::timestamp_1904(1_782_000_000),
        accessed: ft::timestamp_1904(1_782_000_000),
        changed: ft::timestamp_1904(1_782_000_000),
        modified: ft::timestamp_1904(1_782_000_000),
        finder_info: [0; 32],
        link_target: None,
    };
    session.upload_entry(1, &entry).await.unwrap();
    session.upload_data(1, &[7u8; 1000]).await.unwrap();
    session.upload_complete(1).await.unwrap();
    session.cancel_transfer(2).await.unwrap();
    session.start_drag_out(3).await.unwrap();
    session.request_download(4, "/tmp/b.txt").await.unwrap();

    let expected = [
        ft::drag_in_message(1, &[url]),
        ft::upload_destination(1, "/Users/example/Desktop").encode(),
        ft::upload_summary(1, 1600, 1, 0).encode(),
        ft::upload_entry(1, &entry).unwrap().encode(),
        ft::upload_data(1, &[7u8; 1000]).unwrap().encode(),
        ft::upload_complete(1).encode(),
        ft::transfer_cancel(2).encode(),
        ft::drag_out_start(3),
        ft::download_request(4, "/tmp/b.txt").encode(),
    ];
    for message in expected {
        let mut actual = vec![0u8; message.len()];
        server.read_exact(&mut actual).await.unwrap();
        assert_eq!(actual, message);
    }
}

#[tokio::test]
async fn apple_keepalive_and_pasteboard_are_consumed() {
    let (client, mut server) = duplex(64 * 1024);
    let task = tokio::spawn(async move {
        Session::connect_stream(client, SessionConfig::new("mock", 5900))
            .await
            .unwrap()
    });
    perform_handshake(&mut server).await;
    let _ = read_setup(&mut server).await;
    let session = task.await.unwrap();
    let connected = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    // Apple keepalive (id 20): fixed eight bytes.
    server
        .write_all(&[0x14, 0x00, 0x04, 0x00, 0x04, 0x00, 0x01, 0x02])
        .await
        .unwrap();
    // Apple pasteboard (id 31): 16-byte header, compressed length at [12..16].
    let mut pasteboard = vec![0x1f, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 2];
    pasteboard.extend_from_slice(&[0x78, 0xda]);
    server.write_all(&pasteboard).await.unwrap();
    server.write_all(&raw_update()).await.unwrap();

    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(event, Event::Frame { .. }));
}

#[tokio::test]
async fn apple_client_version_message_is_sent_verbatim() {
    let (client, mut server) = duplex(64 * 1024);
    let task = tokio::spawn(async move {
        Session::connect_stream(client, SessionConfig::new("mock", 5900))
            .await
            .unwrap()
    });
    perform_handshake(&mut server).await;
    let _ = read_setup(&mut server).await;
    let session = task.await.unwrap();
    session.send_apple_client_version().await.unwrap();

    let mut message = [0u8; 66];
    server.read_exact(&mut message).await.unwrap();
    assert_eq!(message[0], 0x21);
    assert_eq!(&message[1..6], &[0x00, 0x00, 0x3e, 0x00, 0x01]);
    assert_eq!(&message[34..39], &[0xb0, 0x00, 0x08, 0x03, 0xa0]);
}

#[tokio::test]
async fn download_receives_file() {
    let (client, mut server) = duplex(64 * 1024);
    let task = tokio::spawn(async move {
        Session::connect_stream(client, SessionConfig::new("mock", 5900))
            .await
            .unwrap()
    });
    perform_handshake(&mut server).await;
    let _ = read_setup(&mut server).await;
    let session = task.await.unwrap();
    let connected = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("openscreens-download-{unique}"));
    std::fs::create_dir_all(&root).unwrap();

    session
        .start_download(7, "/remote/hello.txt", root.clone())
        .await
        .unwrap();

    // The client sends a 0x22/0x0001 download request.
    let mut header = [0u8; 14];
    server.read_exact(&mut header).await.unwrap();
    assert_eq!(header[0], 0x22);
    let length = u32::from_be_bytes(header[2..6].try_into().unwrap()) as usize;
    assert_eq!(
        u16::from_be_bytes(header[8..10].try_into().unwrap()),
        ft::SUBTYPE_DOWNLOAD_REQUEST
    );
    assert_eq!(u32::from_be_bytes(header[10..14].try_into().unwrap()), 7);
    let mut payload = vec![0u8; length - 8];
    server.read_exact(&mut payload).await.unwrap();

    let entry = ft::Entry {
        kind: ft::EntryKind::File,
        name: "hello.txt",
        data_size: 5,
        resource_size: 0,
        mode: 0o100_644,
        nesting: 0,
        created: 0,
        accessed: 0,
        changed: 0,
        modified: 0,
        finder_info: [0; 32],
        link_target: None,
    };
    let messages = [
        ft::upload_summary(7, 5, 1, 0).encode(),
        ft::upload_entry(7, &entry).unwrap().encode(),
        ft::upload_data(7, b"hello").unwrap().encode(),
        ft::upload_complete(7).encode(),
    ];
    for message in messages {
        server.write_all(&message).await.unwrap();
    }

    let mut complete = None;
    for _ in 0..8 {
        let event = timeout(Duration::from_secs(1), session.next_event())
            .await
            .unwrap()
            .unwrap();
        if let Event::DownloadComplete {
            handle,
            files,
            bytes,
            error,
            ..
        } = event
        {
            assert_eq!(handle, 7);
            assert_eq!(files, 1);
            assert_eq!(bytes, 5);
            assert!(error.is_none());
            complete = Some(());
            break;
        }
    }
    assert!(complete.is_some());
    assert_eq!(std::fs::read(root.join("hello.txt")).unwrap(), b"hello");
    std::fs::remove_dir_all(&root).ok();
}

#[tokio::test]
async fn apple_desktop_info_populates_displays() {
    let (client, mut server) = duplex(64 * 1024);
    let task = tokio::spawn(async move {
        Session::connect_stream(client, SessionConfig::new("mock", 5900))
            .await
            .unwrap()
    });
    perform_handshake(&mut server).await;
    let _ = read_setup(&mut server).await;
    let session = task.await.unwrap();
    let connected = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    let mut payload = Vec::new();
    payload.extend_from_slice(&3840u16.to_be_bytes());
    payload.extend_from_slice(&2160u16.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&1u16.to_be_bytes());
    payload.extend_from_slice(&7u32.to_be_bytes());
    payload.extend_from_slice(&1920u16.to_be_bytes());
    payload.extend_from_slice(&1080u16.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&[32, 24, 0, 1]);
    payload.extend_from_slice(&255u16.to_be_bytes());
    payload.extend_from_slice(&255u16.to_be_bytes());
    payload.extend_from_slice(&255u16.to_be_bytes());
    payload.extend_from_slice(&[16, 8, 0, 0, 0, 0]);

    let mut update = vec![0, 0];
    update.extend_from_slice(&1u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&1101i32.to_be_bytes());
    update.extend_from_slice(&payload);
    server.write_all(&update).await.unwrap();

    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    let Event::DesktopLayout {
        width,
        height,
        screens,
    } = event
    else {
        panic!("unexpected event: {event:?}");
    };
    assert_eq!((width, height), (3840, 2160));
    assert_eq!(screens.len(), 1);
    assert_eq!(screens[0].id, 7);
    assert_eq!((screens[0].width, screens[0].height), (1920, 1080));
}

async fn perform_apple_handshake(server: &mut DuplexStream) {
    server.write_all(b"RFB 003.889\n").await.unwrap();
    let mut version = [0u8; 12];
    server.read_exact(&mut version).await.unwrap();
    assert_eq!(&version, b"RFB 003.889\n");

    server.write_all(&[1, 1]).await.unwrap();
    let mut security = [0u8; 1];
    server.read_exact(&mut security).await.unwrap();
    assert_eq!(security[0], 1);

    server.write_all(&0u32.to_be_bytes()).await.unwrap();
    let mut client_init = [0u8; 1];
    server.read_exact(&mut client_init).await.unwrap();
    assert_eq!(client_init[0], 0xc1);

    server.write_all(&server_init()).await.unwrap();
    let mut apple = [0u8; 66];
    server.read_exact(&mut apple).await.unwrap();
    assert_eq!(apple[0], 0x21);
}

#[tokio::test]
async fn adaptive_dct_type1_falls_back_to_standard_encodings() {
    let (client, mut server) = duplex(64 * 1024);

    let task = tokio::spawn(async move {
        perform_apple_handshake(&mut server).await;
        let encodings = read_setup(&mut server).await;
        assert!(encodings.contains(&1011));

        let mut update = vec![0, 0];
        update.extend_from_slice(&1u16.to_be_bytes());
        update.extend_from_slice(&0u16.to_be_bytes());
        update.extend_from_slice(&0u16.to_be_bytes());
        update.extend_from_slice(&WIDTH.to_be_bytes());
        update.extend_from_slice(&HEIGHT.to_be_bytes());
        update.extend_from_slice(&1011i32.to_be_bytes());
        update.extend_from_slice(&4u32.to_be_bytes());
        update.extend_from_slice(&[1, 16, 16, 0]);
        server.write_all(&update).await.unwrap();

        let mut header = [0u8; 4];
        server.read_exact(&mut header).await.unwrap();
        assert_eq!(header[0], 2);
        let count = usize::from(u16::from_be_bytes([header[2], header[3]]));
        let mut raw = vec![0u8; count * 4];
        server.read_exact(&mut raw).await.unwrap();
        let ids: Vec<i32> = raw
            .as_chunks::<4>()
            .0
            .iter()
            .map(|id| i32::from_be_bytes([id[0], id[1], id[2], id[3]]))
            .collect();
        assert!(!ids.contains(&1011));

        let mut request = [0u8; 10];
        server.read_exact(&mut request).await.unwrap();
        assert_eq!(request[0], 3);
        assert_eq!(request[1], 0);

        server.write_all(&raw_update()).await.unwrap();
    });

    let mut config = SessionConfig::new("mock", 5900);
    config.apple_session = true;
    config.adaptive_dct = true;
    let session = Session::connect_stream(client, config).await.unwrap();
    let connected = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    let frame = timeout(Duration::from_secs(2), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(frame, Event::Frame { .. }), "got {frame:?}");
    task.await.unwrap();
}

#[tokio::test]
async fn libvncserver_extended_desktop_size_uses_screen_bounds() {
    let (client, mut server) = duplex(64 * 1024);

    let task = tokio::spawn(async move {
        Session::connect_stream(client, SessionConfig::new("mock", 5900))
            .await
            .unwrap()
    });
    perform_handshake(&mut server).await;
    let _ = read_setup(&mut server).await;
    let session = task.await.unwrap();
    let connected = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(connected, Event::Connected { .. }));

    // libvncserver (x11vnc/QEMU) leaves x/y zero and carries the size in the
    // rectangle's width/height plus the screen records.
    let mut update = vec![0, 0];
    update.extend_from_slice(&1u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&WIDTH.to_be_bytes());
    update.extend_from_slice(&HEIGHT.to_be_bytes());
    update.extend_from_slice(&(-308i32).to_be_bytes());
    update.push(1);
    update.extend_from_slice(&[0, 0, 0]);
    update.extend_from_slice(&7u32.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&0u16.to_be_bytes());
    update.extend_from_slice(&WIDTH.to_be_bytes());
    update.extend_from_slice(&HEIGHT.to_be_bytes());
    update.extend_from_slice(&0u32.to_be_bytes());
    server.write_all(&update).await.unwrap();

    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    let Event::DesktopLayout {
        width,
        height,
        screens,
    } = event
    else {
        panic!("unexpected event: {event:?}");
    };
    assert_eq!((width, height), (WIDTH, HEIGHT));
    assert_eq!(screens.len(), 1);
    assert_eq!(screens[0].id, 7);
    assert_eq!((screens[0].width, screens[0].height), (WIDTH, HEIGHT));

    server.write_all(&raw_update()).await.unwrap();
    let frame = timeout(Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(frame, Event::Frame { .. }), "got {frame:?}");
}

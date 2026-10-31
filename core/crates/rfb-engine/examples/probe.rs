//! Connects to a real RFB server and saves the first frame as a BMP.
//!
//! Credentials are read from `OPENSCREENS_USERNAME` and
//! `OPENSCREENS_PASSWORD` so they never live in the repository.

use std::env;
use std::fs::File;
use std::io::{self, Write};
use std::time::Duration;

use rfb_codec::Rect;
use rfb_engine::session::{Event, Session, SessionConfig};
use tokio::time::{Instant, timeout};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args().skip(1);
    let host = args.next().ok_or("usage: probe <host> [port]")?;
    let port = args.next().unwrap_or_else(|| "5900".to_owned());
    let port: u16 = port.parse()?;

    let config = SessionConfig {
        host,
        port,
        username: env::var("OPENSCREENS_USERNAME").ok(),
        password: env::var("OPENSCREENS_PASSWORD").ok(),
        shared: true,
        local_cursor: false,
        quality: 9,
        frame_interval_ms: 16,
        ssh: None,
    };

    let session = Session::connect(config).await?;
    println!(
        "connected name={:?} size={:?} encrypted_input={}",
        session.name(),
        session.size(),
        session.has_input_encryption()
    );

    let deadline = Instant::now() + Duration::from_secs(20);
    let mut frames = 0u32;
    while Instant::now() < deadline {
        match timeout(Duration::from_secs(10), session.next_event()).await {
            Ok(Some(Event::Frame { sequence, rects })) => {
                frames += 1;
                println!("frame {sequence}: {} rects", rects.len());
                if frames == 1
                    && let Some((width, height)) = session.size()
                {
                    let rect = Rect {
                        x: 0,
                        y: 0,
                        width,
                        height,
                    };
                    let pixels = session.copy_region(rect).ok_or("copy failed")?;
                    write_bmp(&pixels, width, height, "target/probe-frame.bmp")?;
                    println!("saved target/probe-frame.bmp ({width}x{height})");
                }
                if frames >= 2 {
                    break;
                }
            }
            Ok(Some(event)) => println!("event: {event:?}"),
            Ok(None) => {
                println!("session ended");
                break;
            }
            Err(_) => {
                println!("timeout waiting for events");
                break;
            }
        }
    }

    if frames == 0 {
        return Err("no frames received".into());
    }
    Ok(())
}

fn write_bmp(pixels: &[u8], width: u16, height: u16, path: &str) -> io::Result<()> {
    let width = u32::from(width);
    let height = u32::from(height);
    let image_size = width * height * 4;
    let file_size = 54 + image_size;
    let stride = width as usize * 4;

    let mut file = File::create(path)?;
    file.write_all(b"BM")?;
    file.write_all(&file_size.to_le_bytes())?;
    file.write_all(&[0, 0, 0, 0])?;
    file.write_all(&54u32.to_le_bytes())?;
    file.write_all(&40u32.to_le_bytes())?;
    file.write_all(&(width as i32).to_le_bytes())?;
    file.write_all(&(height as i32).to_le_bytes())?;
    file.write_all(&1u16.to_le_bytes())?;
    file.write_all(&32u16.to_le_bytes())?;
    file.write_all(&0u32.to_le_bytes())?;
    file.write_all(&image_size.to_le_bytes())?;
    file.write_all(&2835u32.to_le_bytes())?;
    file.write_all(&2835u32.to_le_bytes())?;
    file.write_all(&0u32.to_le_bytes())?;
    file.write_all(&0u32.to_le_bytes())?;

    for row in (0..height as usize).rev() {
        file.write_all(&pixels[row * stride..(row + 1) * stride])?;
    }
    Ok(())
}

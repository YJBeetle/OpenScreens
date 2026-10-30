//! Persistent zlib stream handling for the ZRLE and zlib encodings.

use flate2::{Decompress, FlushDecompress, Status};

use crate::DecodeError;

pub(crate) struct Inflater {
    decompress: Decompress,
}

impl Inflater {
    pub(crate) fn new() -> Self {
        Self {
            decompress: Decompress::new(true),
        }
    }

    /// Inflates one message worth of a persistent zlib stream.
    pub(crate) fn inflate(
        &mut self,
        input: &[u8],
        output: &mut Vec<u8>,
    ) -> Result<(), DecodeError> {
        output.clear();
        output.reserve(input.len().saturating_mul(2).max(256));

        let mut consumed = 0usize;
        let mut stalled = 0u8;
        loop {
            if output.capacity() == output.len() {
                output.reserve(64 * 1024);
            }
            let before_in = self.decompress.total_in();
            let before_out = self.decompress.total_out();
            let status = self
                .decompress
                .decompress_vec(&input[consumed..], output, FlushDecompress::None)
                .map_err(|_| DecodeError::InvalidData("zlib error"))?;
            let new_in = (self.decompress.total_in() - before_in) as usize;
            let new_out = self.decompress.total_out() - before_out;
            consumed += new_in;

            if let Status::StreamEnd = status {
                return Ok(());
            }

            if consumed == input.len() {
                drain(self, output)?;
                return Ok(());
            }

            if new_in == 0 && new_out == 0 {
                stalled += 1;
                if stalled > 2 {
                    return Err(DecodeError::InvalidData("zlib stream stalled"));
                }
                output.reserve(64 * 1024);
            } else {
                stalled = 0;
            }
        }
    }
}

fn drain(inflater: &mut Inflater, output: &mut Vec<u8>) -> Result<(), DecodeError> {
    for _ in 0..16 {
        if output.capacity() == output.len() {
            output.reserve(64 * 1024);
        }
        let before_out = inflater.decompress.total_out();
        let before_in = inflater.decompress.total_in();
        let status = inflater
            .decompress
            .decompress_vec(&[], output, FlushDecompress::Sync)
            .map_err(|_| DecodeError::InvalidData("zlib error"))?;
        if inflater.decompress.total_out() == before_out
            && inflater.decompress.total_in() == before_in
        {
            break;
        }
        if let Status::StreamEnd = status {
            break;
        }
    }
    Ok(())
}

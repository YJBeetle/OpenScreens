//! RFB encoding identifiers (RFC 6143 section 7.7.2 and common extensions).

/// Encodings and pseudo-encodings a client can advertise.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Encoding {
    Raw,
    CopyRect,
    Rre,
    Hextile,
    Zlib,
    Tight,
    Zrle,
    DesktopSize,
    LastRect,
    Cursor,
    XCursor,
    PointerPos,
    ExtendedDesktopSize,
    AppleDesktopInfo,
    AppleDesktopInfo2,
    Fence,
    ContinuousUpdates,
    Other(i32),
}

impl Encoding {
    pub const fn from_id(id: i32) -> Self {
        match id {
            0 => Self::Raw,
            1 => Self::CopyRect,
            2 => Self::Rre,
            5 => Self::Hextile,
            6 => Self::Zlib,
            7 => Self::Tight,
            16 => Self::Zrle,
            -223 => Self::DesktopSize,
            -224 => Self::LastRect,
            -239 => Self::Cursor,
            -240 => Self::XCursor,
            -232 => Self::PointerPos,
            -308 => Self::ExtendedDesktopSize,
            1101 => Self::AppleDesktopInfo,
            1105 => Self::AppleDesktopInfo2,
            -312 => Self::Fence,
            -313 => Self::ContinuousUpdates,
            other => Self::Other(other),
        }
    }

    pub const fn to_id(self) -> i32 {
        match self {
            Self::Raw => 0,
            Self::CopyRect => 1,
            Self::Rre => 2,
            Self::Hextile => 5,
            Self::Zlib => 6,
            Self::Tight => 7,
            Self::Zrle => 16,
            Self::DesktopSize => -223,
            Self::LastRect => -224,
            Self::Cursor => -239,
            Self::XCursor => -240,
            Self::PointerPos => -232,
            Self::ExtendedDesktopSize => -308,
            Self::AppleDesktopInfo => 1101,
            Self::AppleDesktopInfo2 => 1105,
            Self::Fence => -312,
            Self::ContinuousUpdates => -313,
            Self::Other(id) => id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_known_encodings() {
        let ids = [
            0, 1, 2, 5, 6, 7, 16, -223, -224, -239, -240, -232, -308, -312, -313, 1234, -9999,
        ];
        for id in ids {
            assert_eq!(Encoding::from_id(id).to_id(), id);
        }
    }

    #[test]
    fn maps_well_known_ids() {
        assert_eq!(Encoding::from_id(0), Encoding::Raw);
        assert_eq!(Encoding::from_id(1), Encoding::CopyRect);
        assert_eq!(Encoding::from_id(7), Encoding::Tight);
        assert_eq!(Encoding::from_id(16), Encoding::Zrle);
        assert_eq!(Encoding::from_id(-223), Encoding::DesktopSize);
        assert_eq!(Encoding::from_id(-239), Encoding::Cursor);
        assert_eq!(Encoding::from_id(99), Encoding::Other(99));
    }
}

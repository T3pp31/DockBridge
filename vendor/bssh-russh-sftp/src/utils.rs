use bytes::Bytes;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncRead, AsyncReadExt};

use crate::error::Error;

/// Converts to UNIX seconds, flooring like `chrono::DateTime::timestamp` and
/// wrapping pre-epoch (negative) values into `u32` as the chrono-based
/// implementation did.
pub(crate) fn unix(time: SystemTime) -> u32 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs() as u32,
        Err(error) => {
            let before = error.duration();
            let mut secs = before.as_secs() as i64;
            if before.subsec_nanos() > 0 {
                secs += 1;
            }
            secs.wrapping_neg() as u32
        }
    }
}

pub(crate) async fn read_packet<S: AsyncRead + Unpin>(
    stream: &mut S,
    max_length: u32,
) -> Result<Bytes, Error> {
    let length = stream.read_u32().await?;
    if length > max_length {
        return Err(Error::BadMessage("packet length limit exceeded".to_owned()));
    }

    let mut buf = vec![0; length as usize];
    stream.read_exact(&mut buf).await?;

    Ok(Bytes::from(buf))
}

#[cfg(test)]
mod tests {
    use super::unix;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn unix_converts_post_epoch_seconds() {
        assert_eq!(unix(UNIX_EPOCH + Duration::from_secs(1_612_325_106)), 1_612_325_106);
        assert_eq!(unix(UNIX_EPOCH + Duration::from_millis(1_500)), 1);
    }

    #[test]
    fn unix_wraps_pre_epoch_seconds_like_chrono() {
        assert_eq!(unix(UNIX_EPOCH - Duration::from_secs(1)), u32::MAX);
        assert_eq!(unix(UNIX_EPOCH - Duration::from_secs(86_400)), (-86_400i64) as u32);
        // Fractional pre-epoch times floor toward negative infinity.
        assert_eq!(unix(UNIX_EPOCH - Duration::from_millis(500)), u32::MAX);
        assert_eq!(unix(UNIX_EPOCH - Duration::from_millis(1_500)), (-2i64) as u32);
    }
}

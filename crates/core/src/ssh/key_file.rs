//! Private key loading with zeroized file buffers, including error paths.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use russh::keys::{decode_secret_key, PrivateKey};
use zeroize::Zeroizing;

use crate::error::AuthError;

pub(super) fn load_private_key(
    key_path: &Path,
    passphrase: Option<&str>,
) -> Result<PrivateKey, AuthError> {
    let key_contents = File::open(key_path)
        .and_then(read_secret_bytes)
        .map_err(|err| AuthError::PrivateKeyLoadFailed {
            path: key_path.display().to_string(),
            message: err.to_string(),
        })?;
    // Validate UTF-8 by borrowing the guarded bytes, without creating an
    // unprotected String containing the file contents.
    let key_text =
        std::str::from_utf8(&key_contents).map_err(|_| AuthError::PrivateKeyLoadFailed {
            path: key_path.display().to_string(),
            message: "stream did not contain valid UTF-8".to_string(),
        })?;
    decode_secret_key(key_text, passphrase).map_err(|err| AuthError::PrivateKeyLoadFailed {
        path: key_path.display().to_string(),
        message: err.to_string(),
    })
}

fn read_secret_bytes(mut reader: impl Read) -> io::Result<Zeroizing<Vec<u8>>> {
    let mut contents = Zeroizing::new(Vec::new());
    let mut chunk = Zeroizing::new([0u8; 8192]);
    loop {
        let count = match reader.read(&mut chunk[..]) {
            Ok(0) => return Ok(contents),
            Ok(count) => count,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        if contents.capacity() - contents.len() < count {
            // Vec's normal growth frees the previous allocation without wiping
            // it. Copy into a new guarded allocation, then drop (and zeroize)
            // the old one before appending. The append below cannot reallocate.
            let capacity = contents
                .len()
                .saturating_add(count)
                .max(contents.capacity().saturating_mul(2));
            let mut grown = Zeroizing::new(Vec::with_capacity(capacity));
            grown.extend_from_slice(&contents);
            contents = grown;
        }
        contents.extend_from_slice(&chunk[..count]);
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    struct ReaderFn<F>(F);

    impl<F: FnMut(&mut [u8]) -> io::Result<usize>> Read for ReaderFn<F> {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            (self.0)(buffer)
        }
    }

    #[test]
    fn read_empty_secret() {
        let contents = read_secret_bytes(io::empty()).expect("read empty file");
        assert!(contents.is_empty());
    }

    #[test]
    fn read_secret_at_chunk_boundaries() {
        for length in [1, 8191, 8192, 8193, 16_384, 25_000] {
            let expected = vec![b's'; length];
            let contents = read_secret_bytes(Cursor::new(&expected)).expect("read secret");
            assert_eq!(contents.as_slice(), expected.as_slice());
        }
    }

    #[test]
    fn read_secret_across_growth_and_short_reads() {
        let expected: Vec<u8> = (0..25_000).map(|index| (index % 256) as u8).collect();
        let mut source = Cursor::new(&expected);
        let reader = ReaderFn(|buffer: &mut [u8]| {
            let count = buffer.len().min(137);
            source.read(&mut buffer[..count])
        });
        // Keep the returned bytes under zeroize-on-drop ownership as well.
        let contents: Zeroizing<Vec<u8>> =
            read_secret_bytes(reader).expect("read across buffer growth");
        assert_eq!(contents.as_slice(), expected.as_slice());
    }

    #[test]
    fn read_secret_retries_interrupted_after_partial_read() {
        let mut calls = 0;
        let reader = ReaderFn(|buffer: &mut [u8]| {
            calls += 1;
            match calls {
                1 => {
                    buffer[..6].copy_from_slice(b"secret");
                    Ok(6)
                }
                2 => Err(io::Error::from(io::ErrorKind::Interrupted)),
                3 => {
                    buffer[..4].copy_from_slice(b" key");
                    Ok(4)
                }
                _ => Ok(0),
            }
        });
        let contents = read_secret_bytes(reader).expect("retry interrupted read");
        assert_eq!(contents.as_slice(), b"secret key");
        assert_eq!(calls, 4);
    }

    #[test]
    fn read_secret_propagates_error_after_partial_read() {
        let mut calls = 0;
        let reader = ReaderFn(|buffer: &mut [u8]| {
            calls += 1;
            match calls {
                1..=2 => {
                    buffer.fill(b's');
                    Ok(buffer.len())
                }
                3 => {
                    // A failing read may also have modified the scratch buffer.
                    // Both it and the accumulated bytes must remain guarded.
                    buffer[..6].copy_from_slice(b"secret");
                    Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "injected read failure",
                    ))
                }
                _ => panic!("must stop after the I/O error"),
            }
        });
        let err = read_secret_bytes(reader).expect_err("partial read must fail");
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(err.to_string(), "injected read failure");
        assert_eq!(calls, 3);
    }
}

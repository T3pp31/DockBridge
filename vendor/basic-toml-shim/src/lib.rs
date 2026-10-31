//! Minimal drop-in replacement for the unmaintained `basic-toml` crate.
//!
//! UniFFI's Askama dependency only needs `basic_toml::from_str`; route that
//! call to the actively maintained `toml` crate instead.

pub use toml::from_str;

#[cfg(test)]
mod tests {
    #[test]
    fn parses_documents_through_the_maintained_toml_implementation() {
        let value: toml::Value = super::from_str("a = 1").unwrap();
        assert_eq!(value.get("a").and_then(|value| value.as_integer()), Some(1));
    }
}

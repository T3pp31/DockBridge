//! Minimal drop-in replacement for the unmaintained `basic-toml` crate.
//!
//! UniFFI's Askama dependency only needs `basic_toml::from_str`; route that
//! call to the actively maintained `toml` crate instead.

pub use toml::from_str;

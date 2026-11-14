# basic-toml shim

This vendored crate replaces the unmaintained `basic-toml` crate for the one
API used by its dependents: `from_str`. Calls are routed to the maintained
`toml` crate.

Do not add other `basic-toml` APIs here. If an upgrade starts using another
API, update the shim deliberately, verify the replacement with
`cargo tree -i basic-toml`, and keep `toml` unified with `cargo tree -d`.

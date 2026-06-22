/// Policy applied when a transfer completes and the final destination path already exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferOverwritePolicy {
    /// Replace the existing destination after the transfer completes successfully.
    Replace,
    /// Fail without modifying the destination when it already exists.
    FailIfExists,
}

impl Default for TransferOverwritePolicy {
    fn default() -> Self {
        Self::Replace
    }
}

impl TransferOverwritePolicy {
    pub(crate) fn destination_exists_message(path: &str) -> String {
        format!("destination '{path}' already exists and overwrite is disabled")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_policy_replaces_existing_destination() {
        assert_eq!(
            TransferOverwritePolicy::default(),
            TransferOverwritePolicy::Replace
        );
    }
}

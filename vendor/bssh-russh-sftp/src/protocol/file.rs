use std::time::{Duration, UNIX_EPOCH};
use time::OffsetDateTime;

use super::FileAttributes;

const MONTH_ABBREVIATIONS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct File {
    pub filename: String,
    pub longname: String,
    pub attrs: FileAttributes,
}

impl File {
    /// Omits `longname` and set dummy `attributes`. This is mainly used for [`crate::server::Handler::realpath`] as per the standard
    pub fn dummy<S: Into<String>>(filename: S) -> Self {
        Self {
            filename: filename.into(),
            longname: "".to_string(),
            attrs: FileAttributes::dummy(),
        }
    }

    /// Implies the use of longname
    pub fn new<S: Into<String>>(filename: S, attrs: FileAttributes) -> Self {
        let mut file = Self {
            filename: filename.into(),
            longname: "".to_string(),
            attrs,
        };
        file.longname = file.longname();
        file
    }

    /// Get formed longname
    pub fn longname(&self) -> String {
        let directory = if self.attrs.is_dir() { "d" } else { "-" };
        let permissions = self.attrs.permissions().to_string();

        let size = self.attrs.size.unwrap_or(0);
        let mtime = self.attrs.mtime.unwrap_or(0);

        let datetime = OffsetDateTime::from(UNIX_EPOCH + Duration::from_secs(mtime as u64));
        let delayed = format!(
            "{} {:02} {} {:02}:{:02}",
            MONTH_ABBREVIATIONS[datetime.month() as usize - 1],
            datetime.day(),
            datetime.year(),
            datetime.hour(),
            datetime.minute()
        );

        format!(
            "{directory}{permissions} 0 {} {} {size} {delayed} {}",
            if let Some(user) = &self.attrs.user {
                user.to_string()
            } else {
                self.attrs.uid.unwrap_or(0).to_string()
            },
            if let Some(group) = &self.attrs.group {
                group.to_string()
            } else {
                self.attrs.gid.unwrap_or(0).to_string()
            },
            self.filename
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::FileAttributes;

    #[test]
    fn longname_formats_mtime_like_the_previous_chrono_layout() {
        // Given: a file whose mtime is 2021-02-03T04:05:06Z (1612325106)
        let mut attrs = FileAttributes::dummy();
        attrs.mtime = Some(1_612_325_106);

        // When: the longname is built
        let longname = File::new("file.txt", attrs).longname;

        // Then: the date uses the same "%b %d %Y %H:%M" layout
        assert!(
            longname.contains("Feb 03 2021 04:05"),
            "unexpected longname: {longname}"
        );
    }
}

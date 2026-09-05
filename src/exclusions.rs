//! Dropbox's built-in metadata and temporary-file exclusions.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// Excluding a directory also excludes everything beneath it.
pub(crate) fn is_excluded(path: &Path) -> bool {
    path.iter().any(is_excluded_name)
}

/// Dropbox documents suffixes for metadata files and prefixes for temporary files:
/// <https://help.dropbox.com/en-en/sync/files-not-syncing>.
pub(crate) fn is_excluded_name(name: &OsStr) -> bool {
    let bytes = name.as_bytes();
    bytes.starts_with(b"~$")
        || bytes.starts_with(b".~")
        || [
            b"desktop.ini".as_slice(),
            b"thumbs.db",
            b".ds_store",
            b"icon\r",
            b".dropbox",
            b".dropbox.attr",
        ]
        .iter()
        .any(|suffix| {
            bytes.len() >= suffix.len()
                && bytes[bytes.len() - suffix.len()..].eq_ignore_ascii_case(suffix)
        })
}

#[cfg(test)]
mod tests {
    use super::is_excluded;
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    #[test]
    fn documented_names_and_descendants_are_excluded() {
        for path in [
            ".DS_Store",
            "folder/DESKTOP.INI",
            "folder/Thumbs.db",
            "folder/Icon\r",
            "folder/.dropbox",
            "folder/.DROPBOX.ATTR",
            "folder/metadata.ds_store",
            "folder/~$draft.docx",
            "folder/.~draft.docx",
            "folder/.dropbox/child.txt",
            "~$temporary/child.txt",
        ] {
            assert!(is_excluded(Path::new(path)), "{path:?}");
        }
        assert!(is_excluded(Path::new(OsStr::from_bytes(b"folder/~$\xff"))));
    }

    #[test]
    fn other_names_still_sync() {
        for path in [
            "notes.md",
            ".obsidian/settings.json",
            ".gitignore",
            "file.tmp",
            "file~",
            "DS_Store",
            ".DS_Store.backup",
            "thumbs.db.txt",
            "icon",
            "icon\\r",
            "rules.dropboxignore",
            ".dropbox-folder/notes.md",
        ] {
            assert!(!is_excluded(Path::new(path)), "{path:?}");
        }
    }
}

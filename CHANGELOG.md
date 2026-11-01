# Changelog

## 2.2.0

- Fixed copying same-name folders: directories now merge recursively instead of stopping at the first collision. Destination-only files are preserved.
- Added Skip, Keep both, Replace file and Stop copying for file collisions, with an optional policy for the current upload only.
- Added Unicode/case-equivalent name matching and explicit handling of file-versus-folder conflicts.
- Replacement stages the incoming file before renaming through a backup; failed transfers preserve the original. Rename/cleanup failures report retained recovery files.
- Added a completion summary with copied, merged and skipped counts.
- Added merge/conflict/rollback regression tests and real-device validation, including downloaded-content verification and the native Skip dialog.

## 2.1.1

- Fixed reconnection after unplugging and reconnecting a Switch without restarting the app.
- Added read-only USB registry monitoring and automatic creation of a fresh MTP session on reattachment, including USB-address reuse.
- Connect now pings an existing session and replaces an unresponsive idle helper instead of assuming a running process is connected.
- Old helper events and pending deletion confirmations cannot affect a new session. Interrupted writes are kept for explicit user review and are never replayed automatically.
- Added native lifecycle regression tests with fake helpers; MTP ping tests also verify storage-list replacement and failure handling.

## 2.1.0

- Renamed Games to Install games (Установка игр).
- Added confirmed deletion of non-empty folder trees on SD Card.
- Added a read-only deletion preview with file/folder counts and file size, session-bound confirmation tokens, tree revalidation and leaf-first execution.
- Cancellation before confirmation leaves the tree unchanged. Stopping an active deletion keeps changes already made.
- Added tests for missing/expired confirmation, changed contents, cycles, storage guards and partial failures; validated a generated nested tree on real DBI hardware.

## 2.0.0

- Added a remote file browser with storage selection, folder navigation, breadcrumbs and search.
- Added Finder drag-and-drop uploads for files and folder trees, including drops onto folder rows.
- Added individual file downloads, new folders, rename and confirmed deletion of files or empty folders.
- Added read-only guards for storages other than SD Card, cross-storage checks and no-overwrite transfers.
- Added instant English/Russian switching, remembered language choice and localized macOS menus.
- Preserved the persistent MTP session and recoverable installation queue.
- Built the bundled libraries from included source archives for macOS 13 and later on Apple Silicon.
- Added a DBI adapter for directory enumeration and integration tests for file operations.

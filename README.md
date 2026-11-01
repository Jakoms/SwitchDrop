# SwitchDrop

**A native macOS file manager and game transfer tool for Nintendo Switch running DBI.**

Browse your Switch, drop files from Finder, and send game packages through one persistent USB MTP connection. SwitchDrop uses SwiftUI and AppKit, with English and Russian interfaces.

[Download for Apple Silicon](https://github.com/Jakoms/SwitchDrop/releases/latest) · [Русская инструкция](README.ru.md)

## Features

- **File browser:** storage picker, folder navigation, breadcrumbs, search and contextual actions.
- **Finder drag & drop:** copy files or entire folders into the current SD folder, or drop onto a folder row. Matching folders merge recursively and preserve destination-only files.
- **File operations:** download individual files, create folders, rename items and delete files or entire folder trees after confirmation.
- **Game queue:** NSP, NSZ, XCI and XCZ packages sent sequentially to DBI's **SD Card Install** storage.
- **Transfer feedback:** per-file progress, speed, estimated remaining time and cancellation.
- **Persistent connection:** browsing and transfers share one open MTP session. USB detach/replug replaces the expired session automatically; Connect checks an existing session and recovers an unresponsive idle helper.
- **RU / EN button:** switch the interface and macOS menus instantly; your choice is remembered.
- **Queue recovery:** the queue survives relaunches. Interrupted transfers require an explicit retry from the beginning.

## Requirements and installation

- Apple Silicon Mac, macOS 13 or later.
- Nintendo Switch running [DBI](https://github.com/rashevskyv/dbi) in **Run MTP responder** mode.
- A USB cable that supports data transfer.

Download the application ZIP from [Releases](https://github.com/Jakoms/SwitchDrop/releases), unzip it, and move **SwitchDrop.app** to Applications. The app includes its MTP libraries; no Homebrew or Terminal is needed to use it.

The release is ad-hoc signed and is not notarized by Apple. macOS may require **Open Anyway** in Privacy & Security when launching it for the first time. No system security setting needs to be disabled.

Quit other MTP clients, including OpenMTP and Android File Transfer, before connecting. Start MTP Responder on the Switch, open SwitchDrop, and click **Connect** if necessary.

## Files or game installation?

The **Files** tab copies files into ordinary SD-card folders. It does not install game packages. Use the **Install games** tab to install packages through DBI's virtual **SD Card Install** storage. A successful MTP transfer is not independent verification of a successful installation; check DBI's screen.

In Files, choose a storage and double-click a folder to open it. Drop files or folders from Finder into the table, or onto a folder row. Use the toolbar or context menu to download, rename or delete an item. Double-clicking a file opens a save dialog to download it.

Changes are enabled only on **SD Card**. Other browsable storages are read-only in SwitchDrop. Virtual installation storages are handled by the Install games tab. DBI determines which storages are exposed.

Folder names are matched case-insensitively, including Unicode and equivalent composed/decomposed names. Existing directories are reused recursively; their other contents are retained. File conflicts offer **Skip**, **Keep both**, **Replace file**, or **Stop copying**, with an optional choice for all file conflicts in the current upload. File-versus-folder conflicts cannot silently replace a directory; skip, keep both, or manage the destination explicitly.

File replacement uploads a temporary copy first, then swaps names through a backup. A failed transfer preserves the original. Replacement needs free space for the incoming file while the original still exists. If a rename or backup cleanup fails, the error explains the remaining `.switchdrop-upload` / `.switchdrop-backup` files. Downloads use a temporary local file and commit without replacing an existing destination. Symlinks and filesystem special files are not uploaded. A failed folder upload may leave the files that were already copied. Deletion first scans the selected item and shows file/folder counts and total file size. Nothing is removed before confirmation. The helper revalidates the tree before deleting its contents from the leaves up; changed contents require a new confirmation. Deletion has no Trash recovery. Stopping a deletion preserves changes already made.

## Transfer behavior

- Operations run one at a time. An installation error stops the queue.
- Cancellation is cooperative and may wait for DBI to respond. A partial item can remain after an interrupted upload.
- There is no byte-offset resume and no automatic replay of interrupted transfers or deletions. Reconnection restores the session and browser only.
- Files larger than 4 GB use 64-bit sizes. DBI manages storage-specific handling; SwitchDrop does not split local files.
- NSZ/XCZ packages can require more space when installed than their compressed source size.
- While transferring, the app requests prevention of idle system sleep. Closing the lid and manual sleep are not prevented.
- Recursive upload is supported. Folder download, moving files between remote folders and NAND installation are not implemented.
- The current version connects to the first available Nintendo MTP device. Disconnect additional consoles if needed.

Queue state: `~/Library/Application Support/SwitchDrop/queue.json`. Diagnostic log: `~/Library/Application Support/SwitchDrop/session.log`. Logs can contain local filenames; review them before sharing.

## Build from source

Install Xcode Command Line Tools, Python 3 for tests, and pkg-config (`brew install pkgconf`). Then:

```sh
./Source/build.sh
python3 Tests/test_backend.py
python3 Tests/test_browser.py
python3 Tests/test_adapter.py
python3 Tests/test_delete.py
python3 Tests/test_connection.py
python3 Tests/test_merge.py
```

The build verifies and compiles the included libusb 1.0.30 and libmtp 1.1.23 source archives, bundles the libraries, and ad-hoc signs the application. The default deployment target is macOS 13.0; libraries are built with the same target. No network access is required by the build once pkg-config and the developer tools are installed.

A small, included libmtp extension handles DBI directory enumeration through `GetObjectPropList`: root queries address the storage object, while the UI and uploads use the MTP root handle `0xFFFFFFFF`. It filters the returned properties to the requested storage and direct children. Ordinary `GetObjectHandles` is retained as a fallback.

The source is organized into `Source/main.swift` (application and session state), `Browser.swift` (browser UI and actions), `Localization.swift` (language support), `USBMonitor.swift` (read-only USB presence monitoring), `mtp-helper.c` (session and installation protocol), `mtp-browser.h` (file operations), `mtp-upload.h` (recursive merging and conflict resolution), and `mtp-delete.h` (two-phase deletion). The helper reads length-prefixed NUL-separated UTF-8 commands from stdin and emits JSON events. Paths are never passed through a shell.

See [TESTING.md](TESTING.md) for validation coverage and limits.

## License

SwitchDrop and its DBI adapter are MIT licensed. Bundled **libmtp** and **libusb** are LGPL-2.1; complete upstream source archives, the adapter, build scripts, checksums, licenses and author notices are included. See [Licenses/THIRD-PARTY.md](Licenses/THIRD-PARTY.md).

SwitchDrop is an independent project and is not affiliated with Nintendo or the DBI authors. No games, console keys or firmware are included.

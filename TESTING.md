# Validation

The C helper is tested against an in-memory libmtp responder. The tests do not open USB devices.

`Tests/test_backend.py` covers installation-target isolation, USB and serial identity, 64-bit sizes with an 8 GiB sparse file, stop-on-error, cancellation, empty-file rejection and one persistent session across discovery and multiple batches.

`Tests/test_browser.py` covers directory listing and navigation, new folders, rename, deleting empty folders, refusing non-empty folder deletion, recursive upload, download SHA-256, refusing destination overwrite, read-only storages, mismatched object/storage IDs, name collisions and symlink rejection.

The Swift `--self-test` covers fragmented UTF-8 JSON events, 64-bit counters, binary command framing, queue persistence, interrupted recovery, duplicate filtering, failure state and language selection.

The build checks the application signature. Both bundled dynamic libraries and the executable target macOS 13. Runtime testing on macOS 13 hardware has not been performed; the development Mac runs macOS 27.

Hardware validation of the persistent-session installer completed a file larger than 4 GB and subsequent small packages. MTP transport confirmation does not independently verify the installed title on the console.

Hardware file-browser checks passed on a Nintendo Switch running DBI: SD-root enumeration, mkdir, upload with a UTF-8 filename, rename, individual download with matching SHA-256, deletion of the generated file and empty test folder. All operations shared one MTP session.

A Finder drag-and-drop test copied a 38-byte text file to the SD card, confirmed by both the application log and the refreshed directory listing. Folder navigation and the RU/EN button were checked in the live UI; the English interface also updated the macOS menu.

`Tests/test_adapter.py` checks the actual adapter code with synthetic MTP property datasets: storage-object root requests, exclusion of the storage object itself, filtering direct children and unrelated storages, 64-bit sizes, and fallback when the optional operation is unsupported.

`Tests/test_delete.py` covers the read-only preview, confirmation token, cancellation without deletion, recursive leaf-first deletion, revalidation of changed contents, root and cross-storage rejection, cycle rejection and partial-failure reporting.

Hardware validation for 2.1.0 created a generated tree containing 3 files and 3 folders (12 bytes of file data). The preview reported these counts correctly. Cancellation kept the tree; a subsequent confirmed commit removed all 6 items. No existing user files were deleted for this test.

`Tests/test_connection.py` exercises the actual Swift Store and Process/pipe lifecycle using a fake helper. It covers healthy-session ping without reopening, USB detach/replug, address reuse, direct re-enumeration, stale-event isolation, interrupted-write recovery, clearing old deletion confirmations, no automatic replay, hung idle-helper replacement and shutdown. The fake helper does not open USB. Native USB enumeration reads IOKit registry properties without claiming the interface.

For 2.1.1, the installed UI was verified to clear the previous connected state while the Switch was physically absent. A complete physical detach/replug cycle has not yet been confirmed; the automated lifecycle regression scenarios above passed.

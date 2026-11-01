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

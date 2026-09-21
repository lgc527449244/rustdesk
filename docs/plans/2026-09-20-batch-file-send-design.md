# Batch File Send

- Status: implemented (desktop only)
- Date: 2026-09-20

## Problem

The RustDesk client can transfer files to a single device from the
"File Transfer" tab. Sending the same files to many devices requires
opening N tabs, typing the same path, and repeating each upload. This is
tedious for technicians who need to push installers, scripts, or assets
to a fleet.

## Goal

Add a "Batch Send" tool which:

- accepts a list of local files/folders and one remote target directory;
- accepts a list of devices (recent + address-book + LAN + groups,
  deduped, plus manually entered IDs);
- opens one **headless** file-transfer session per device and uploads the
  files into the target directory in parallel (configurable 1–4);
- shows per-device live status, progress, speed, error reason, and a
  retry/cancel affordance per device.

No desktop-window-per-device, no `WindowController`, no extra Rust core
changes; the Flutter model layer orchestrates everything.

## Approach

The work lives entirely in the Flutter side and is driven by a single
new singleton `BatchFileSender` (`flutter/lib/models/batch_send_model.dart`)
which uses a brand-new headless event hook on `FFI`.

### Headless session

A new "headless" mode is exposed by adding one optional field to
`FFI`:

```dart
bool Function(Map<String, dynamic> evt)? headlessEventHook;
```

In `FFI.start`'s `stream.listen`, after `json.decode(message.field0)`
produces an `event`, the code now checks the hook first:

```dart
if (event != null) {
  final hook = headlessEventHook;
  if (hook == null || !hook(event)) {
    await cb(event);
  }
}
```

The hook returning `true` skips the normal `cb(event)` dispatch, which
is exactly what a dialog-less session needs to suppress msgbox
overlays, auto-answer `override_file_confirm`, and consume
`job_progress`/`job_done`/`job_error`/`update_folder_files` for its own
state machine. The rest of the event handling (peer_info, permissions,
chat, etc.) is left to the default dispatch, which is safe because all
those handlers either populate global state, call global FRB queries, or
operate on `parent.target?.dialogManager` (no-op when there are no
dialogs).

The connection close event is special: it is delivered as the raw
string `"close"` before JSON decoding, so the hook does not see it.
`FFI.closed` is set there, and the model's stall timer / connect wait
loop watches it.

### Per-task flow

For every selected device, `BatchFileSender` builds a `BatchSendTask`
that owns:

- its own `FFI(null)` instance (`FfiModel` defaults to file-transfer
  connType);
- the items to send (one `BatchSendItem` per selected local path);
- reactive status / progress / speed / hint / error.

`tasks` are scheduled through a tiny pump (`_schedule` / `_launch` /
`_activeRunners`) which respects a configurable concurrency (1..4, default
2). Each launcher invokes `_runTask`, which:

1. `ffi.start(peerId, isFileTransfer: true, password:)` (Rust does
   `sessionAddSync → sessionStart` automatically). A fresh UUID is used
   for the local session id so we can never collide with the main
   `gFFI.sessionId`.
2. Waits up to 30 s for `ffi.ffiModel.pi.isSet.value == true` (200 ms
   poll), checking `ffi.closed` and the task's own `_finished` flag.
3. Once connected, captures `isWindowsPeer = pi.platform == 'Windows'`
   and starts a 5 s `stallTimer` that fails the task if
   `ffi.closed` becomes true (peer disconnected) or no job progress
   has arrived for 120 s.
4. Iterates through `items` sequentially:
   - picks a fresh `jobId` via `JobController.jobID.next()` (Rust
     `mainGetCommonSync('transfer-job-id')` is global, monotonic,
     race-free);
   - `bind.sessionSendFiles(sessionId, jobId, localPath,
     to: PathUtil.join(target, basename, isWindowsPeer), …, isDir:
     item.isDir)`;
   - if the item is a directory, fires an async helper which uses
     `bind.sessionReadLocalEmptyDirsRecursiveSync` +
     `bind.sessionCreateDir` (mirrors `FileModel.sendFiles` exactly);
   - awaits a per-item `Completer<bool>` completed by the hook on
     `job_done` / `job_error`.
5. On the last item, marks the task as `done`; on error or cancel,
   tears the session down via `ffi.close()`.

### Event hook

The hook consumes the events a headless session must not delegate to
the standard UI dispatch and returns `false` for everything else (so
`peer_info`, `connection_ready`, `permission`, `sync_*`, etc. continue
to work as before, in particular they let `_pi.isSet` flip to `true`
during the connect wait).

| Event name                  | Action                                                 |
| --------------------------- | ------------------------------------------------------ |
| `msgbox`                    | If `hasRetry == 'true'` → transient hint, keep going. Else classify by type (`re-input-password`/`input-password`, `input-2fa`, `session-login*`/`session-re-login`, anything else with `text`) and fail the task. |
| `toast`                     | Consumed silently (would otherwise be noisy across many devices). |
| `override_file_confirm`     | Auto-answered via `bind.sessionSetConfirmOverrideFile(remember: true)` using the current per-task policy (overwrite/skip). |
| `job_progress`              | Update per-item `finishedSize`/`speed`, `task.lastProgressAt`, task progress, task speed. |
| `job_done`                  | Complete the per-item completer with `true`. |
| `job_error`                 | If `err == 'skipped'` (skipped via policy) mark item done, complete completer `true`. Otherwise `_finish(failed, err)`. |
| `file_dir` / `empty_dirs` / `load_last_job` / `update_folder_files` | Consumed silently; `update_folder_files` is parsed to refine `totalSize` for directory items. |

Stall / close detection is done by polling (the timer for stalls, the
200 ms loop for connection).

### Tasks coexistence with the visible File Transfer tab

`rustdesk-core`'s `SESSIONS` map is keyed by `(peer_id, conn_type)`,
not by session id; multiple UI handlers are stored in
`session.session_handlers` and `push_event` fan-outs to all of them
when `includes`/`excludes` is empty. Therefore opening a headless
batch session to peer X while a visible "File Transfer" tab for peer
X is also open reuses the same underlying TCP/Relay connection; the
visible tab still receives all events (its own job table ignores our
job ids) and the headless hook still receives them. Edge case is
documented below in the Limitations section.

### Teardown

`_finish` is the single teardown path, guarded by
`task._finished` so it is idempotent under double-event races:

1. cancel the stall timer;
2. cancel the per-item completer with `false` (unblocks the runner);
3. clear the hook on the FFI (`ffi.headlessEventHook = null`);
4. best-effort `bind.sessionCancelJob` on the active job;
5. `await ffi.fileModel.close()` (dismisses dialogs, stops the
   `evtLoop`);
6. `await ffi.close()` (Rust `session_close` removes the local handler;
   the underlying connection survives if another UI handler exists).
7. set the task's reactive `error` / `status`.

### UI

A new desktop tab page (`flutter/lib/desktop/pages/batch_send_page.dart`)
hosts a single ~760-wide centered column with:

- Header: "Batch Send" + subtitle "Send files to multiple devices".
- Local files block: chips for each selected path, buttons "Add
  files" / "Add folder" / "Clear".
- Target path: single text field; a small hint about the inferred
  Windows/Unix style based on `\` or `^[A-Za-z]:`.
- Options: optional password, overwrite policy dropdown
  (overwrite/skip), concurrency dropdown (1–4).
- Devices: search field + checkbox list built from
  `gFFI.abModel.allPeers() ∪ gFFI.recentPeersModel.peers ∪
  gFFI.recentPeersModel.restPeerIds ∪ gFFI.lanPeersModel.peers ∪
  gFFI.groupModel.peers` (dedupe by id); "Select all" / "Clear" plus a
  Refresh button which triggers `bind.mainLoadRecentPeers()` +
  `bind.mainLoadLanPeers()` if the lists are empty.
- Start button: validates non-empty paths / target / peers before
  invoking `controller.start`.
- Tasks list: one row per device showing alias/id, status chip,
  `LinearProgressIndicator`, current file name, speed, hint, and
  per-row Retry / Cancel buttons. "Stop all" and "Clear finished" at
  the top.

A new entry button in the main window's left pane (`buildLeftPane`,
only when `!isIncomingOnly`) opens the page through a new static
`DesktopTabPage.onAddBatchSend`, which mirrors `onAddSetting`.

## Changes

### Added

- `docs/plans/2026-09-20-batch-file-send-design.md` — this file.
- `flutter/lib/models/batch_send_model.dart` — `BatchSendItem`,
  `BatchSendTask`, `BatchPeerTarget`, `BatchFileSender`,
  `BatchOverwritePolicy`, `BatchSendStatus`.
- `flutter/lib/desktop/pages/batch_send_page.dart` — UI.

### Edited

- `flutter/lib/models/model.dart` — `FFI.headlessEventHook` field;
  `stream.listen` hook check.
- `flutter/lib/consts.dart` — `kTabLabelBatchSendPage`.
- `flutter/lib/desktop/pages/desktop_tab_page.dart` —
  `onAddBatchSend` static method + import.
- `flutter/lib/desktop/pages/desktop_home_page.dart` — entry button in
  `buildLeftPane`.
- `src/lang/cn.rs` — new keys (Chinese; English falls back to the key
  itself via `translate_locale` so `src/lang/en.rs` was extended too).

### Not touched

- Rust core (`src/`): the existing `push_event` fan-out behaviour and
  the `sessions::insert_session` API already support multi-UI
  sessions; no protocol or backend changes are needed.

## Scope

### In

- Local file and folder selection via `FilePicker`.
- Sequential files, parallel devices (1..4).
- One target directory per task; relative layout preserved for
  directories.
- Auto overwrite / auto skip policy with per-job `remember: true` so
  subsequent files in the same job don't re-prompt.
- Password-protected peers (per-task optional password).
- Retry and cancel per task; stop-all + clear-finished.
- Detects connection close (via `FFI.closed` poll) and stalls
  (no progress for 120 s).
- Reuses the cached `transfer-job-id` counter (monotonic, race-free).

### Out (v1)

- Resumable uploads (any transfer interruption restarts the affected
  item from zero).
- v2: bidirectional overrides (overwrite-or-prompt per file),
  in-page peer filter by online-only, exclude-list selection, address-
  book group "send to group" sugar, file collisions when the
  destination exists with non-identical content (currently always
  overwrite/skip by policy), directory-level checksum pre-check.
- Mobile (Android/iOS) UI — desktop only.
- Any change to the Rust core; the entire feature lives in the Flutter
  app and piggy-backs on the existing `FFI.start`/`sessionStart` API.

### Known edge cases

- If a visible File Transfer tab is already open for the same peer, the
  headless session joins the same Rust session (fan-out events). The
  batch sender still owns its own items (per-`jobId`) and ignore the
  visible tab's events; the visible tab's `dialogManager` may show a
  password dialog during a reconnect, but `BatchSendTask` is
  independent of that overlay.
- Peers that show the "Multiple Windows sessions found" picker
  (`set_multiple_windows_session`) cannot be addressed headlessly in v1;
  the connection wait reaches its 30 s deadline and the task fails with
  a clear message.
- Linux/macOS peers requiring `sudo` for the target path are not
  special-cased; if the remote file transfer is denied by the OS, a
  msgbox failure is reported with the Rust message text.
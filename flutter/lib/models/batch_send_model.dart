import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

/// Headless batch file sending.
///
/// One [BatchSendTask] per target device. Each task owns its own
/// file-transfer [FFI] session which is started without any window/page:
/// the session's event stream is intercepted via [FFI.headlessEventHook]
/// so that password prompts, 2FA, overwrite confirmations and progress
/// updates are handled programmatically instead of being shown as
/// dialogs.

/// Maximum time to wait for a single device to finish connecting.
const int kBatchConnectTimeoutSeconds = 30;

/// Maximum time the transfer may stall (no progress event) before the
/// task is considered failed.
const int kBatchStallTimeoutSeconds = 120;

/// Maximum number of devices processed in parallel.
const int kBatchMaxConcurrency = 4;

/// Status of a single device in the batch sender.
enum BatchSendStatus {
  pending,
  connecting,
  sending,
  done,
  failed,
  cancelled,
}

/// User-selected policy for handling an existing destination file.
enum BatchOverwritePolicy { overwrite, skip }

/// Minimal information about a remote device, passed to the batch sender
/// when the user clicks "Start sending".
class BatchPeerTarget {
  BatchPeerTarget({
    required this.id,
    this.alias = '',
    this.platform = '',
  });

  final String id;
  final String alias;
  final String platform;

  String get displayName => alias.isEmpty ? id : alias;
}

/// One local file or folder that should be sent.
class BatchSendItem {
  BatchSendItem({required this.localPath, this.totalSize = 0});

  final String localPath;

  /// Bytes reported by the local walker; refined when the remote
  /// server sends `update_folder_files` for directory jobs.
  int totalSize;

  /// Bytes already transferred (for the currently active job).
  int finishedSize = 0;

  /// The job id assigned by the Rust core (unique per session).
  int jobId = -1;

  /// Last reported speed (bytes/sec) for this item.
  double speed = 0;

  /// True when the file was skipped by the overwrite policy and the
  /// Rust core reports a `job_error` with `err == "skipped"`.
  bool skipped = false;

  String get fileName => path.basename(localPath);

  bool get isDir {
    try {
      return FileSystemEntity.isDirectorySync(localPath);
    } catch (_) {
      return false;
    }
  }
}

/// One device's task: drives its own headless file-transfer session.
class BatchSendTask {
  BatchSendTask({
    required this.peerId,
    required this.peerAlias,
    required this.peerPlatform,
    required this.items,
  });

  final String peerId;
  final String peerAlias;
  final String peerPlatform;
  final List<BatchSendItem> items;

  String get displayName => peerAlias.isEmpty ? peerId : peerAlias;

  final status = BatchSendStatus.pending.obs;
  final error = ''.obs;
  final hint = ''.obs;
  final progress = 0.0.obs;
  final speedText = ''.obs;

  /// The headless FFI instance owned by this task. Created in `_launch`
  /// and torn down in `_finish`.
  FFI? ffi;

  /// True if the remote device reports its platform as "Windows".
  bool isWindowsPeer = false;

  // Internal, not reactive.
  bool _finished = false;
  BatchSendItem? currentItem;
  Completer<bool>? itemCompleter;
  DateTime? lastProgressAt;
  Timer? stallTimer;

  int get totalSize => items.fold(0, (s, e) => s + e.totalSize);
  int get finishedSize => items.fold(0, (s, e) => s + e.finishedSize);

  /// Look up the item currently associated with a Rust job id. Returns
  /// `null` for events that don't belong to this task.
  BatchSendItem? itemByJobId(int? id) {
    if (id == null) return null;
    for (final item in items) {
      if (item.jobId == id) return item;
    }
    return null;
  }

  String humanStatusText() {
    switch (status.value) {
      case BatchSendStatus.pending:
        return translate('Pending');
      case BatchSendStatus.connecting:
        return translate('Connecting');
      case BatchSendStatus.sending:
        return translate('Sending');
      case BatchSendStatus.done:
        return translate('Finished');
      case BatchSendStatus.failed:
        return translate('Failed');
      case BatchSendStatus.cancelled:
        return translate('Cancelled');
    }
  }

  void updateProgress() {
    final total = totalSize;
    progress.value = total > 0
        ? (finishedSize / total).clamp(0.0, 1.0).toDouble()
        : 0.0;
  }

  void updateSpeed() {
    final item = currentItem;
    if (item == null || status.value != BatchSendStatus.sending) {
      speedText.value = '';
      return;
    }
    speedText.value = item.speed <= 0
        ? ''
        : '${_formatFileSize(item.speed.toInt())}/s';
  }
}

/// Singleton controller owning the batch sender state and pump.
class BatchFileSender extends GetxController {
  static BatchFileSender get instance {
    if (!Get.isRegistered<BatchFileSender>()) {
      Get.put<BatchFileSender>(BatchFileSender(), permanent: true);
    }
    return Get.find<BatchFileSender>();
  }

  final tasks = <BatchSendTask>[].obs;
  final running = false.obs;

  // Options captured when the user clicks "Start sending". These are
  // shared between tasks (one user input, many targets).
  final targetPath = ''.obs;
  final targetPathIsWindows = false.obs;
  final password = ''.obs;
  final overwritePolicy = BatchOverwritePolicy.overwrite.obs;
  final concurrency = 2.obs;

  // The local files/folders picked by the user.
  final selectedPaths = <String>[].obs;

  int _activeRunners = 0;
  bool _stopAll = false;

  // ---------------------------------------------------------------------
  // Selection helpers (used by the UI).
  // ---------------------------------------------------------------------

  void addPaths(List<String> paths) {
    for (final p in paths) {
      if (p.isEmpty) continue;
      if (!selectedPaths.contains(p)) {
        selectedPaths.add(p);
      }
    }
  }

  void removePath(String p) {
    selectedPaths.remove(p);
  }

  void clearPaths() {
    selectedPaths.clear();
  }

  void clearFinishedTasks() {
    tasks.removeWhere((t) =>
        t.status.value == BatchSendStatus.done ||
        t.status.value == BatchSendStatus.failed ||
        t.status.value == BatchSendStatus.cancelled);
  }

  // ---------------------------------------------------------------------
  // Public lifecycle entry points.
  // ---------------------------------------------------------------------

  /// Build one task per peer and schedule them. Returns `true` if
  /// anything was scheduled, `false` if the input was invalid or a
  /// previous batch is still running.
  Future<bool> start(List<BatchPeerTarget> peers) async {
    if (running.value || peers.isEmpty || selectedPaths.isEmpty) {
      return false;
    }
    _stopAll = false;
    tasks.clear();

    // Pre-compute local sizes once: every task shares the same items.
    final sizes = <String, int>{};
    for (final p in selectedPaths) {
      sizes[p] = await computeLocalSize(p);
    }

    for (final peer in peers) {
      tasks.add(BatchSendTask(
        peerId: peer.id,
        peerAlias: peer.alias,
        peerPlatform: peer.platform,
        items: [
          for (final p in selectedPaths)
            BatchSendItem(localPath: p, totalSize: sizes[p] ?? 0),
        ],
      ));
    }

    running.value = true;
    _schedule();
    return true;
  }

  void retryTask(BatchSendTask task) {
    final st = task.status.value;
    if (st != BatchSendStatus.failed && st != BatchSendStatus.cancelled) {
      return;
    }
    _resetTask(task);
    task.status.value = BatchSendStatus.pending;
    if (!running.value) {
      _stopAll = false;
      running.value = true;
    }
    _schedule();
  }

  void cancelTask(BatchSendTask task) {
    final st = task.status.value;
    if (st == BatchSendStatus.pending) {
      task.status.value = BatchSendStatus.cancelled;
      return;
    }
    if (st == BatchSendStatus.connecting || st == BatchSendStatus.sending) {
      _finish(task, BatchSendStatus.cancelled);
    }
  }

  void stopAll() {
    _stopAll = true;
    for (final t in tasks.toList()) {
      cancelTask(t);
    }
  }

  // ---------------------------------------------------------------------
  // Pump.
  // ---------------------------------------------------------------------

  void _resetTask(BatchSendTask task) {
    task._finished = false;
    task.error.value = '';
    task.hint.value = '';
    task.progress.value = 0;
    task.speedText.value = '';
    for (final item in task.items) {
      item.finishedSize = 0;
      item.jobId = -1;
      item.skipped = false;
      item.speed = 0;
    }
    task.currentItem = null;
    task.itemCompleter = null;
    task.lastProgressAt = null;
    task.isWindowsPeer = false;
  }

  void _schedule() {
    final maxC = concurrency.value.clamp(1, kBatchMaxConcurrency);
    while (!_stopAll && _activeRunners < maxC) {
      BatchSendTask? next;
      for (final t in tasks) {
        if (t.status.value == BatchSendStatus.pending) {
          next = t;
          break;
        }
      }
      if (next == null) break;
      _launch(next);
    }
    if (_activeRunners == 0) {
      running.value = false;
    }
  }

  void _launch(BatchSendTask task) {
    _activeRunners++;
    // Claim the task synchronously so a parallel `_schedule` invocation
    // doesn't pick the same pending entry twice.
    task.status.value = BatchSendStatus.connecting;
    () async {
      try {
        await _runTask(task);
      } catch (e, st) {
        debugPrint('batch send task error: $e\n$st');
        if (!task._finished &&
            (task.status.value == BatchSendStatus.connecting ||
                task.status.value == BatchSendStatus.sending)) {
          await _finish(task, BatchSendStatus.failed, e.toString());
        }
      } finally {
        _activeRunners--;
      }
      if (!_stopAll) {
        _schedule();
      } else if (_activeRunners == 0) {
        running.value = false;
      }
    }();
  }

  Future<void> _runTask(BatchSendTask task) async {
    task.error.value = '';
    task.hint.value = '';
    task.updateProgress();
    task.updateSpeed();

    final ffi = FFI(null);
    task.ffi = ffi;
    ffi.headlessEventHook = (evt) => _handleEvent(task, evt);

    try {
      ffi.start(task.peerId,
          isFileTransfer: true, password: password.value);
    } catch (e) {
      await _finish(task, BatchSendStatus.failed,
          '${translate('Error')}: $e');
      return;
    }

    final ok = await _waitConnected(task);
    if (task._finished) return;
    if (!ok) {
      await _finish(
          task,
          BatchSendStatus.failed,
          task.error.value.isEmpty
              ? translate('Connection timed out')
              : task.error.value);
      return;
    }

    task.isWindowsPeer = ffi.ffiModel.pi.platform == 'Windows';
    task.status.value = BatchSendStatus.sending;
    task.hint.value = '';
    task.lastProgressAt = DateTime.now();
    _startStallTimer(task);

    for (final item in task.items) {
      if (task._finished ||
          task.status.value != BatchSendStatus.sending) {
        return;
      }
      final remotePath =
          PathUtil.join(targetPath.value, item.fileName, task.isWindowsPeer);
      final jobId = JobController.jobID.next();
      item.jobId = jobId;
      item.finishedSize = 0;
      item.speed = 0;
      item.skipped = false;
      task.currentItem = item;
      task.itemCompleter = Completer<bool>();
      task.lastProgressAt = DateTime.now();
      task.updateProgress();
      task.updateSpeed();

      try {
        bind.sessionSendFiles(
            sessionId: ffi.sessionId,
            actId: jobId,
            path: item.localPath,
            to: remotePath,
            fileNum: 0,
            includeHidden: true,
            isRemote: false,
            isDir: item.isDir);
      } catch (e) {
        await _finish(task, BatchSendStatus.failed,
            '${translate('Error')}: $e');
        return;
      }

      if (item.isDir) {
        // Best-effort empty-dir reproduction; matches FileModel.sendFiles.
        // ignore: discarded_futures
        _createRemoteEmptyDirs(task, item);
      }

      final completer = task.itemCompleter!;
      final itemOk = await completer.future;
      if (task._finished) return;
      if (!itemOk) {
        // _finish has already been called by whoever completed the
        // completer with false (job_error / msgbox / cancel).
        return;
      }
      item.finishedSize = item.totalSize;
      item.speed = 0;
      task.currentItem = null;
      task.itemCompleter = null;
      task.updateProgress();
      task.updateSpeed();
    }

    if (!task._finished) {
      await _finish(task, BatchSendStatus.done);
    }
  }

  Future<bool> _waitConnected(BatchSendTask task) async {
    final ffi = task.ffi;
    if (ffi == null) return false;
    final deadline = DateTime.now()
        .add(const Duration(seconds: kBatchConnectTimeoutSeconds));
    while (DateTime.now().isBefore(deadline)) {
      if (task._finished) return false;
      if (ffi.closed) return false;
      if (ffi.ffiModel.pi.isSet.value) {
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  void _startStallTimer(BatchSendTask task) {
    task.stallTimer?.cancel();
    task.stallTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final ffi = task.ffi;
      if (ffi == null) return;
      if (ffi.closed) {
        _finish(task, BatchSendStatus.failed,
            translate('Connection interrupted'));
        return;
      }
      final last = task.lastProgressAt;
      if (last != null &&
          DateTime.now().difference(last).inSeconds >
              kBatchStallTimeoutSeconds) {
        _finish(task, BatchSendStatus.failed,
            translate('Connection interrupted'));
      }
    });
  }

  // ---------------------------------------------------------------------
  // Event hook (runs inside the headless session's stream listener).
  // Returns `true` to consume an event so the default UI dispatch is
  // skipped.
  // ---------------------------------------------------------------------

  bool _handleEvent(BatchSendTask task, Map<String, dynamic> evt) {
    if (task._finished) return true;
    try {
      switch (evt['name']) {
        case 'msgbox':
          _handleMsgbox(task, evt);
          return true;
        case 'toast':
          return true;
        case 'override_file_confirm':
          _autoConfirmOverride(task, evt);
          return true;
        case 'job_progress':
          _handleJobProgress(task, evt);
          return true;
        case 'job_done':
          _handleJobDone(task, evt);
          return true;
        case 'job_error':
          _handleJobError(task, evt);
          return true;
        case 'update_folder_files':
          _handleUpdateFolderFiles(task, evt);
          return true;
        case 'file_dir':
        case 'empty_dirs':
        case 'load_last_job':
          return true;
      }
    } catch (e) {
      debugPrint('batch event handling error: $e');
    }
    // Anything else (peer_info, connection_ready, permission, ...): let
    // the standard dispatch run so global state stays consistent.
    return false;
  }

  void _handleMsgbox(BatchSendTask task, Map<String, dynamic> evt) {
    final type = '${evt['type'] ?? ''}';
    final title = '${evt['title'] ?? ''}';
    final text = '${evt['text'] ?? ''}';

    // Transient errors with auto-retry: keep waiting. The hint is shown
    // to the user in the task row.
    if (evt['hasRetry'] == 'true') {
      task.hint.value = text.isNotEmpty ? text : title;
      return;
    }

    String message;
    if (type == 're-input-password' || type == 'input-password') {
      message = translate('Password required or incorrect');
    } else if (type == 'input-2fa') {
      message = translate('2FA code required');
    } else if (type.startsWith('session-login') ||
        type == 'session-re-login') {
      message = translate('OS login required');
    } else {
      message = text.isNotEmpty ? text : title;
    }

    if (task.status.value == BatchSendStatus.connecting ||
        task.status.value == BatchSendStatus.sending) {
      _finish(task, BatchSendStatus.failed, message);
    }
  }

  Future<void> _autoConfirmOverride(
      BatchSendTask task, Map<String, dynamic> evt) async {
    final ffi = task.ffi;
    if (ffi == null) return;
    final actId = int.tryParse('${evt['id']}') ?? 0;
    final fileNum = int.tryParse('${evt['file_num']}') ?? 0;
    final isUpload = evt['is_upload'] == 'true';
    final needOverride =
        overwritePolicy.value == BatchOverwritePolicy.overwrite;
    try {
      await bind.sessionSetConfirmOverrideFile(
          sessionId: ffi.sessionId,
          actId: actId,
          fileNum: fileNum,
          needOverride: needOverride,
          remember: true,
          isUpload: isUpload);
      task.lastProgressAt = DateTime.now();
    } catch (e) {
      debugPrint('batch: failed to confirm override file: $e');
    }
  }

  void _handleJobProgress(BatchSendTask task, Map<String, dynamic> evt) {
    final id = int.tryParse('${evt['id']}');
    final item = task.itemByJobId(id);
    if (item == null) return;
    item.finishedSize =
        double.tryParse('${evt['finished_size']}')?.toInt() ?? 0;
    item.speed = double.tryParse('${evt['speed']}') ?? 0;
    task.lastProgressAt = DateTime.now();
    task.updateProgress();
    task.updateSpeed();
  }

  void _handleJobDone(BatchSendTask task, Map<String, dynamic> evt) {
    final id = int.tryParse('${evt['id']}');
    final item = task.itemByJobId(id);
    if (item == null) return;
    final c = task.itemCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(true);
    }
  }

  void _handleJobError(BatchSendTask task, Map<String, dynamic> evt) {
    final id = int.tryParse('${evt['id']}');
    final item = task.itemByJobId(id);
    final err = '${evt['err'] ?? ''}';
    if (item != null && err == 'skipped') {
      item.skipped = true;
      item.finishedSize = item.totalSize;
      task.updateProgress();
      final c = task.itemCompleter;
      if (c != null && !c.isCompleted) {
        c.complete(true);
      }
      return;
    }
    if (item != null) {
      _finish(task, BatchSendStatus.failed, err);
    }
  }

  void _handleUpdateFolderFiles(
      BatchSendTask task, Map<String, dynamic> evt) {
    try {
      final raw = evt['info'];
      if (raw is! String) return;
      final info = jsonDecode(raw);
      if (info is! Map) return;
      final id = info['id'];
      final item = task.itemByJobId(id is int ? id : int.tryParse('$id'));
      if (item == null || !item.isDir) return;
      final total = (info['total_size'] as num?)?.toInt() ?? 0;
      if (total > 0) {
        item.totalSize = total;
        task.updateProgress();
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Teardown.
  // ---------------------------------------------------------------------

  Future<void> _finish(
      BatchSendTask task, BatchSendStatus status,
      [String error = '']) async {
    if (task._finished) return;
    task._finished = true;

    task.stallTimer?.cancel();
    task.stallTimer = null;

    // Unblock the runner first (it may still be awaiting the completer
    // after we tear the session down).
    final c = task.itemCompleter;
    final currentJobId = task.currentItem?.jobId ?? -1;
    task.itemCompleter = null;
    task.currentItem = null;
    if (c != null && !c.isCompleted) {
      c.complete(false);
    }

    final ffi = task.ffi;
    task.ffi = null;
    if (ffi != null) {
      ffi.headlessEventHook = null;
      if (currentJobId >= 0 &&
          (status == BatchSendStatus.failed ||
              status == BatchSendStatus.cancelled)) {
        try {
          await bind.sessionCancelJob(
              sessionId: ffi.sessionId, actId: currentJobId);
        } catch (e) {
          debugPrint('batch: failed to cancel job: $e');
        }
      }
      try {
        await ffi.fileModel.close();
      } catch (e) {
        debugPrint('batch: failed to close file model: $e');
      }
      try {
        await ffi.close();
      } catch (e) {
        debugPrint('batch: failed to close FFI: $e');
      }
    }

    task.hint.value = '';
    task.error.value = error;
    task.status.value = status;
    if (status == BatchSendStatus.done) {
      for (final item in task.items) {
        item.finishedSize = item.totalSize;
      }
      task.progress.value = 1.0;
      task.updateSpeed();
    }
  }

  // ---------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------

  Future<void> _createRemoteEmptyDirs(
      BatchSendTask task, BatchSendItem item) async {
    final ffi = task.ffi;
    if (ffi == null) return;
    try {
      final res = await bind.sessionReadLocalEmptyDirsRecursiveSync(
          sessionId: ffi.sessionId,
          path: item.localPath,
          includeHidden: true);
      if (res.isEmpty) return;
      final fdJsons = jsonDecode(res);
      if (fdJsons is! List) return;
      final localParent = path.dirname(item.localPath);
      for (final fdJson in fdJsons) {
        if (fdJson is! Map) continue;
        final fd = FileDirectory.fromJson(fdJson.cast<String, dynamic>());
        var dir = fd.path;
        if (task.isWindowsPeer != isWindows) {
          dir = PathUtil.convert(dir, isWindows, task.isWindowsPeer);
        }
        final peerPath = PathUtil.getOtherSidePath(localParent, dir, isWindows,
            targetPath.value, task.isWindowsPeer);
        try {
          bind.sessionCreateDir(
              sessionId: ffi.sessionId,
              actId: JobController.jobID.next(),
              path: peerPath,
              isRemote: true);
        } catch (e) {
          debugPrint('batch: sessionCreateDir failed: $e');
        }
      }
    } catch (e) {
      debugPrint(
          'batch: failed to create empty dirs for ${item.localPath}: $e');
    }
  }
}

/// Walk a local file or directory recursively and return its byte size.
/// Returns 0 for unreadable paths.
Future<int> computeLocalSize(String p) async {
  try {
    final type = FileSystemEntity.typeSync(p);
    if (type == FileSystemEntityType.directory) {
      var total = 0;
      await for (final entity
          in Directory(p).list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
      return total;
    }
    if (type == FileSystemEntityType.file) {
      return await File(p).length();
    }
  } catch (e) {
    debugPrint('batch: failed to compute size of $p: $e');
  }
  return 0;
}

/// Format a byte count for display.
String _formatFileSize(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024.0;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024.0;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024.0).toStringAsFixed(2)} GB';
}

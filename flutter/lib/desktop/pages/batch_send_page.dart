import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/batch_send_model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

/// Batch file sending page (desktop only).
///
/// Pick local files/folders, type one remote target directory, select the
/// target devices and start. Each selected device gets its own headless
/// file-transfer session managed by [BatchFileSender].
class BatchSendPage extends StatefulWidget {
  const BatchSendPage({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _BatchSendPageState();
}

class _BatchSendPageState extends State<BatchSendPage> {
  final controller = BatchFileSender.instance;

  final _targetController = TextEditingController();
  final _passwordController = TextEditingController();
  final _searchController = TextEditingController();

  BatchOverwritePolicy _policy = BatchOverwritePolicy.overwrite;
  int _concurrency = 2;
  final _selectedPeerIds = <String>{};
  List<Peer> _allPeers = [];

  final String _peerListenerKey = 'BatchSendPage';

  @override
  void initState() {
    super.initState();
    gFFI.recentPeersModel.addListener(_mergePeers);
    gFFI.lanPeersModel.addListener(_mergePeers);
    gFFI.abModel.addPeerUpdateListener(_peerListenerKey, _mergePeers);
    gFFI.groupModel.addPeerUpdateListener(_peerListenerKey, _mergePeers);
    if (gFFI.recentPeersModel.peers.isEmpty) {
      bind.mainLoadRecentPeers();
    }
    if (gFFI.lanPeersModel.peers.isEmpty) {
      bind.mainLoadLanPeers();
    }
    _mergePeers();
  }

  @override
  void dispose() {
    gFFI.recentPeersModel.removeListener(_mergePeers);
    gFFI.lanPeersModel.removeListener(_mergePeers);
    gFFI.abModel.removePeerUpdateListener(_peerListenerKey);
    gFFI.groupModel.removePeerUpdateListener(_peerListenerKey);
    _targetController.dispose();
    _passwordController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _mergePeers() {
    final merged = <String, Peer>{};
    void addAll(List<Peer> peers) {
      for (final p in peers) {
        if (p.id.isNotEmpty && !merged.containsKey(p.id)) {
          merged[p.id] = p;
        }
      }
    }

    try {
      addAll(gFFI.abModel.allPeers());
    } catch (_) {}
    try {
      addAll(gFFI.groupModel.peers.toList());
    } catch (_) {}
    try {
      addAll(gFFI.lanPeersModel.peers.toList());
    } catch (_) {}
    try {
      addAll(gFFI.recentPeersModel.peers.toList());
    } catch (_) {}
    try {
      for (final id in gFFI.recentPeersModel.restPeerIds) {
        if (!merged.containsKey(id)) {
          merged[id] = Peer.fromJson({'id': id});
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _allPeers = merged.values.toList();
      });
    }
  }

  List<Peer> get _filteredPeers {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _allPeers;
    return _allPeers.where((p) {
      return p.id.toLowerCase().contains(query) ||
          p.alias.toLowerCase().contains(query) ||
          p.hostname.toLowerCase().contains(query) ||
          p.username.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                _buildLocalFilesSection(),
                _buildTargetSection(),
                _buildOptionsSection(),
                _buildPeersSection(),
                _buildStartButton(),
                _buildProgressSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate('Batch Send'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4.0),
          Text(
            translate('Send files to multiple devices'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall,
      ),
    );
  }

  Widget _buildLocalFilesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(translate('Local files')),
        Obx(() {
          final paths = controller.selectedPaths;
          if (paths.isEmpty) {
            return Text(
              translate('No file selected'),
              style: Theme.of(context).textTheme.bodySmall,
            );
          }
          return Wrap(
            spacing: 6.0,
            runSpacing: 6.0,
            children: paths
                .map((p) => Chip(
                      label: Text(
                        p,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onDeleted: () => controller.removePath(p),
                    ))
                .toList(),
          );
        }),
        const SizedBox(height: 8.0),
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.upload_file, size: 18.0),
              label: Text(translate('Add files')),
              onPressed: _addFiles,
            ),
            const SizedBox(width: 8.0),
            OutlinedButton.icon(
              icon: const Icon(Icons.folder_open, size: 18.0),
              label: Text(translate('Add folder')),
              onPressed: _addFolder,
            ),
            const SizedBox(width: 8.0),
            TextButton(
              onPressed: controller.clearPaths,
              child: Text(translate('Clear')),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _addFiles() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (res != null) {
      controller.addPaths(res.paths.whereType<String>().toList());
    }
  }

  Future<void> _addFolder() async {
    final p = await FilePicker.platform.getDirectoryPath();
    if (p != null && p.isNotEmpty) {
      controller.addPaths([p]);
    }
  }

  Widget _buildTargetSection() {
    final target = _targetController.text.trim();
    final isWinStyle =
        target.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(target);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(translate('Target path')),
        TextField(
          controller: _targetController,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            hintText: isWindows
                ? r'C:\Users\Public\Documents'
                : '/home/user/Desktop',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 4.0),
        Text(
          translate('Target path tip'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (target.isNotEmpty)
          Text(
            isWinStyle ? 'Windows' : 'Unix',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
      ],
    );
  }

  Widget _buildOptionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(translate('Options')),
        Wrap(
          spacing: 16.0,
          runSpacing: 12.0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
              child: TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: translate('Password (optional)'),
                ),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<BatchOverwritePolicy>(
                value: _policy,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: translate('Overwrite policy'),
                ),
                items: [
                  DropdownMenuItem(
                    value: BatchOverwritePolicy.overwrite,
                    child: Text(translate('Overwrite')),
                  ),
                  DropdownMenuItem(
                    value: BatchOverwritePolicy.skip,
                    child: Text(translate('Skip existing')),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _policy = v);
                  }
                },
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<int>(
                value: _concurrency,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: translate('Concurrency'),
                ),
                items: List.generate(
                  kBatchMaxConcurrency,
                  (i) => DropdownMenuItem(
                    value: i + 1,
                    child: Text('${i + 1}'),
                  ),
                ),
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _concurrency = v);
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPeersSection() {
    final peers = _filteredPeers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(translate('Devices')),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.search, size: 18.0),
                  hintText: translate('Search'),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8.0),
            TextButton(
              onPressed: () {
                for (final p in peers) {
                  _selectedPeerIds.add(p.id);
                }
                setState(() {});
              },
              child: Text(translate('Select all')),
            ),
            TextButton(
              onPressed: () {
                _selectedPeerIds.clear();
                setState(() {});
              },
              child: Text(translate('Clear')),
            ),
            IconButton(
              tooltip: translate('Refresh'),
              onPressed: () {
                bind.mainLoadRecentPeers();
                bind.mainLoadLanPeers();
              },
              icon: const Icon(Icons.refresh, size: 20.0),
            ),
          ],
        ),
        const SizedBox(height: 8.0),
        Container(
          height: 220,
          decoration: BoxDecoration(
            border: Border.all(
                color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(4.0),
          ),
          child: peers.isEmpty
              ? Center(
                  child: Text(
                    translate('No devices found'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (context, index) {
                    final peer = peers[index];
                    final selected = _selectedPeerIds.contains(peer.id);
                    return InkWell(
                      onTap: () {
                        setState(() {
                          if (selected) {
                            _selectedPeerIds.remove(peer.id);
                          } else {
                            _selectedPeerIds.add(peer.id);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12.0, vertical: 2.0),
                        child: Row(
                          children: [
                            Checkbox(
                              value: selected,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selectedPeerIds.add(peer.id);
                                  } else {
                                    _selectedPeerIds.remove(peer.id);
                                  }
                                });
                              },
                            ),
                            getOnline(8.0, peer.online),
                            Expanded(
                              child: Text(
                                peer.alias.isEmpty
                                    ? formatID(peer.id)
                                    : peer.alias,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${peer.username}@${peer.hostname}',
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildStartButton() {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: Obx(() => ElevatedButton.icon(
            icon: const Icon(Icons.send, size: 18.0),
            label: Text(translate('Start sending')),
            onPressed:
                controller.running.value ? null : _startSend,
          )),
    );
  }

  void _startSend() {
    if (controller.selectedPaths.isEmpty) {
      _snack(translate('No file selected'));
      return;
    }
    final target = _targetController.text.trim();
    if (target.isEmpty) {
      _snack(translate('Invalid target path'));
      return;
    }
    if (_selectedPeerIds.isEmpty) {
      _snack(translate('No device selected'));
      return;
    }
    controller.targetPath.value = target;
    controller.targetPathIsWindows.value =
        target.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(target);
    controller.password.value = _passwordController.text;
    controller.overwritePolicy.value = _policy;
    controller.concurrency.value = _concurrency;

    final peers = _allPeers
        .where((p) => _selectedPeerIds.contains(p.id))
        .map((p) => BatchPeerTarget(
            id: p.id, alias: p.alias, platform: p.platform))
        .toList();
    for (final id in _selectedPeerIds) {
      if (!peers.any((p) => p.id == id)) {
        peers.add(BatchPeerTarget(id: id));
      }
    }
    // ignore: discarded_futures
    controller.start(peers);
  }

  void _snack(String message) {
    showToast(message);
  }

  Widget _buildProgressSection() {
    return Obx(() {
      final tasks = controller.tasks;
      if (tasks.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(translate('Progress')),
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed:
                    controller.running.value ? controller.stopAll : null,
                child: Text(translate('Stop all')),
              ),
              TextButton(
                onPressed: controller.clearFinishedTasks,
                child: Text(translate('Clear finished')),
              ),
            ],
          ),
          Container(
            height: 300,
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4.0),
            ),
            child: ListView.builder(
              itemCount: tasks.length,
              itemBuilder: (context, index) {
                final task = tasks[index];
                return _buildTaskRow(task);
              },
            ),
          ),
        ],
      );
    });
  }

  Widget _buildTaskRow(BatchSendTask task) {
    return Obx(() {
      final status = task.status.value;
      Color statusColor;
      switch (status) {
        case BatchSendStatus.done:
          statusColor = Colors.green;
          break;
        case BatchSendStatus.failed:
          statusColor = Colors.red;
          break;
        case BatchSendStatus.cancelled:
          statusColor = kColorWarn;
          break;
        default:
          statusColor = Theme.of(context).colorScheme.primary;
      }
      return Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                getOnline(6.0, true),
                Expanded(
                  child: Text(
                    task.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  task.humanStatusText(),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: statusColor),
                ),
                const SizedBox(width: 12.0),
                if (status == BatchSendStatus.failed ||
                    status == BatchSendStatus.cancelled)
                  TextButton(
                    onPressed: () => controller.retryTask(task),
                    child: Text(translate('Retry')),
                  ),
                if (status == BatchSendStatus.connecting ||
                    status == BatchSendStatus.sending ||
                    status == BatchSendStatus.pending)
                  TextButton(
                    onPressed: () => controller.cancelTask(task),
                    child: Text(translate('Cancel')),
                  ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: task.progress.value <= 0
                        ? null
                        : task.progress.value,
                    minHeight: 4.0,
                  ),
                ),
                const SizedBox(width: 8.0),
                SizedBox(
                  width: 40.0,
                  child: Text(
                    task.progress.value > 0
                        ? '${(task.progress.value * 100).toStringAsFixed(0)}%'
                        : '',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  width: 110.0,
                  child: Text(
                    task.speedText.value,
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (task.error.value.isNotEmpty)
              Text(
                task.error.value,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.red),
              ),
            if (task.hint.value.isNotEmpty)
              Text(
                task.hint.value,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: kColorWarn),
              ),
          ],
        ),
      );
    });
  }
}
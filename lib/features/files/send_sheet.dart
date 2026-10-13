import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/application/agents/agents.dart' show hostsProvider;
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/picker_row.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/files/files_sheet.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';
import 'package:upgrade/platform/shell/remote_shell.dart' show remotePathFor;

const sendSheetLinger = Duration(milliseconds: 700);

Future<void> showSendSheet(BuildContext context, List<SharedItem> items) =>
    showPanelSheet<void>(
      context,
      title: 'SEND TO HOST',
      builder: (_) => SendSheet(items: items),
    );

class SendSheet extends ConsumerStatefulWidget {
  const SendSheet({super.key, required this.items});

  final List<SharedItem> items;

  @override
  ConsumerState<SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends ConsumerState<SendSheet> {
  Host? _host;
  String? _status;
  bool _busy = false;
  TransferJob? _job;
  bool _sent = false;
  Future<void> Function()? _retry;
  ({String host, List<String> at})? _clipped;
  List<String> _landed = const [];
  List<QueuedFile> _queue = const [];
  List<AttachItem> _items = const [];

  late final List<SharedFile> _shared = widget.items
      .whereType<SharedFile>()
      .toList();

  @override
  void dispose() {
    if (!_busy) unawaited(discardCopies(_shared.map((f) => f.path)));
    super.dispose();
  }

  List<int> get _all => [for (var i = 0; i < _shared.length; i++) i];

  Future<HostFiles?> _open(Host host) async {
    try {
      return await ref.read(hostFilesOpenerProvider)(host);
    } catch (error) {
      if (mounted) setState(() => _status = filesFailureLine(error));
      return null;
    }
  }

  Future<List<int>> _upload(
    Host host,
    String verb,
    List<int> which,
    QueueTask task,
  ) async {
    if (which.isEmpty) return const [];
    final queue = [
      for (final i in which)
        QueuedFile(name: _shared[i].name, bytes: _shared[i].size),
    ];
    final items = [for (final file in queue) AttachItem(bytes: file.bytes)];
    if (!mounted) return which;
    final job = _job = ref
        .read(transfersProvider)
        .begin(verb: verb, host: host.name, files: queue);
    setState(() {
      _status = verb;
      _queue = queue;
      _items = items;
    });
    final failures = await runQueue(
      queue,
      (i, report, stop) => task(which[i], report, stop),
      stop: job.stop,
      onItem: (index, item) {
        items[index] = item;
        job.report(index, item);
        if (mounted) setState(() {});
      },
    ).whenComplete(job.end);
    final pending = [
      for (var i = 0; i < which.length; i++)
        if (failures[i] != null) which[i],
    ];
    final failed = failures
        .where((f) => f != null && f != stoppedFailure)
        .length;
    if (pending.isEmpty) return pending;
    if (mounted) {
      setState(
        () => _status = job.stop.stopped
            ? '$verb · STOPPED'
            : '$verb · $failed FAILED',
      );
    }
    return pending;
  }

  void _begin() => setState(() {
    _busy = true;
    _retry = null;
    _landed = const [];
  });

  Future<void> _toClipboard(
    Host host, {
    List<String>? paths,
    List<int>? which,
  }) async {
    if (_clipped case final clipped? when clipped.host == host.id) {
      paths ??= clipped.at;
      which ??= const [];
    }
    _begin();
    final files = await _open(host);
    if (files == null) {
      _retry = () => _toClipboard(host, paths: paths, which: which);
      return await _done(false);
    }
    try {
      final todo = which ?? _all;
      final sharing = uploadsSharing(todo.length);
      final at =
          paths ??
          [
            for (final file in _shared)
              remotePathFor('${const Uuid().v4()}/${file.name}'),
          ];
      final pending = await _upload(
        host,
        'UPLOADING',
        todo,
        (i, report, stop) => pushFile(
          files,
          at[i],
          File(_shared[i].path),
          report,
          sharing: sharing,
          stop: stop,
        ),
      );
      if (pending.isNotEmpty) {
        _retry = () => _toClipboard(host, paths: at, which: pending);
        return await _done(false);
      }
      var next = 0;
      final landed = [
        for (final item in widget.items) item is SharedFile ? at[next++] : null,
      ];
      final failed = switch (planClipboard(widget.items, landed)) {
        CopyText(:final text) => await files.copy(text: text),
        CopyImage(:final path, :final mime) => await files.copy(
          imageAt: path,
          mime: mime,
        ),
      };
      if (!mounted) return;
      setState(() {
        _status = failed == null ? 'COPIED' : 'CLIPBOARD · $failed';
        if (failed != null && at.isNotEmpty) {
          _landed = at;
          _clipped = (host: host.id, at: at);
        }
      });
      await _done(failed == null);
    } finally {
      files.close();
    }
  }

  Future<void> _toFolder(Host host, {String? into, List<int>? which}) async {
    final folder = into ?? await pickHostFolder(context, host);
    if (folder == null || !mounted) return;
    _begin();
    Future<void> again(List<int> which) =>
        _toFolder(host, into: folder, which: which);
    final todo = which ?? _all;
    final files = await _open(host);
    if (files == null) {
      _retry = () => again(todo);
      return await _done(false);
    }
    try {
      final listed = await files.list(folder);
      if (listed == null) {
        if (mounted) setState(() => _status = 'FOLDER · $unreadFolder');
        _retry = () => again(todo);
        return await _done(false);
      }
      final taken = {for (final entry in listed) entry.name};
      String claim(String name) {
        final free = freeName(name, taken);
        taken.add(free);
        return free;
      }

      final names = {for (final i in todo) i: claim(_shared[i].name)};
      final sharing = uploadsSharing(todo.length);
      final pending = await _upload(
        host,
        'UPLOADING',
        todo,
        (i, report, stop) => pushFile(
          files,
          joinPath(folder, names[i]!),
          File(_shared[i].path),
          report,
          sharing: sharing,
          stop: stop,
        ),
      );
      if (pending.isNotEmpty) {
        _retry = () => again(pending);
        return await _done(false);
      }
      final now = DateTime.now();
      for (final text in widget.items.whereType<SharedText>()) {
        final write = await files.put(
          joinPath(folder, claim(sharedTextName(now))),
          FileBody.bytes(utf8.encode(text.text)),
        );
        if (write.failure case final failure?) {
          if (mounted) setState(() => _status = 'TEXT · $failure');
          _retry = () => again(const []);
          return await _done(false);
        }
      }
      if (mounted) setState(() => _status = 'IN ${folder.split('/').last}');
      await _done(true);
    } finally {
      files.close();
    }
  }

  Future<void> _done(bool sent) async {
    _sent = sent;
    if (!mounted) return discardCopies(_shared.map((f) => f.path));
    setState(() => _busy = false);
    if (!sent) return;
    await discardCopies(_shared.map((f) => f.path));
    await Future<void>.delayed(sendSheetLinger);
    if (mounted) Navigator.of(context).pop();
  }

  String _summary() {
    final texts = widget.items.whereType<SharedText>().length;
    final bytes = _shared.fold<int>(0, (sum, file) => sum + file.size);
    return [
      if (_shared.isNotEmpty)
        '${_shared.length} ${_shared.length == 1 ? 'FILE' : 'FILES'} · ${sizeWord(bytes)}',
      if (texts > 0) '$texts ${texts == 1 ? 'TEXT' : 'TEXTS'}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final loaded = ref.watch(hostsProvider);
    final hosts = loaded.value ?? const <Host>[];
    final host = _host ?? (hosts.length == 1 ? hosts.single : null);
    final text = widget.items.whereType<SharedText>().firstOrNull?.text;
    return PanelSheetBody(
      title: 'SEND TO HOST',
      affordance: PanelAffordance(
        _job == null ? 'CANCEL' : 'CLOSE',
        showIcon: false,
        onTap: () => Navigator.of(context).pop(),
      ),
      footer: [
        if (host != null && !_sent)
          Row(
            children: [
              ActionBlock(
                key: const ValueKey('send-clipboard'),
                label: 'CLIPBOARD',
                onTap: _busy ? null : () => unawaited(_toClipboard(host)),
              ),
              const SizedBox(width: Spacing.md),
              ActionBlock(
                key: const ValueKey('send-folder'),
                label: 'FOLDER',
                onTap: _busy ? null : () => unawaited(_toFolder(host)),
              ),
            ],
          ),
        if (_status case final status?) ...[
          if (host != null && !_sent) const SizedBox(height: Spacing.sm),
          Row(
            children: [
              if (_busy) ...[
                const DotSpinner(),
                const SizedBox(width: Spacing.md),
              ],
              Expanded(
                child: Text(
                  status,
                  key: const ValueKey('send-status'),
                  style: tokens.label,
                ),
              ),
              if (_busy && _job != null && !_job!.ended && !_job!.stop.stopped)
                ActionBlock(
                  key: const ValueKey('send-stop'),
                  label: 'STOP',
                  tone: tokens.danger,
                  onTap: () => setState(_job!.stop.stop),
                )
              else if (!_busy && _retry != null)
                ActionBlock(
                  key: const ValueKey('send-retry'),
                  label: 'RETRY',
                  onTap: () => unawaited(_retry!()),
                ),
            ],
          ),
        ],
      ],
      children: [
        Text(
          _summary(),
          key: const ValueKey('send-summary'),
          style: tokens.label.copyWith(color: tokens.textSecondary),
        ),
        if (text != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            text,
            style: tokens.value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SheetRule(),
        if (!loaded.hasValue)
          const Row(children: [DotSpinner()])
        else if (hosts.isEmpty)
          const EmptyState('no hosts')
        else
          for (final candidate in hosts)
            PickerRow(
              key: ValueKey('send-host-${candidate.id}'),
              label: candidate.name,
              selected: candidate.id == host?.id,
              onTap: () {
                if (_busy || candidate.id == host?.id) return;
                setState(() {
                  _host = candidate;
                  _retry = null;
                  _landed = const [];
                });
              },
            ),
        if (_landed.isNotEmpty) ...[
          const SheetRule(),
          Text(
            'ON THE HOST AT',
            style: tokens.label.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: Spacing.sm),
          SelectableText(
            _landed.join('\n'),
            key: const ValueKey('send-landed'),
            style: tokens.value,
          ),
        ],
        if (_items.isNotEmpty) ...[
          const SheetRule(),
          TransferQueue(files: _queue, items: _items, keyPrefix: 'send'),
        ],
      ],
    );
  }
}

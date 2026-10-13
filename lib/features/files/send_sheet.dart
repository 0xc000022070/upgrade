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
  bool _sent = false;
  List<AttachItem> _items = const [];

  late final List<SharedFile> _shared = widget.items
      .whereType<SharedFile>()
      .toList();

  @override
  void dispose() {
    if (!_busy) unawaited(discardCopies(_shared.map((f) => f.path)));
    super.dispose();
  }

  List<QueuedFile> get _queue => [
    for (final file in _shared) QueuedFile(name: file.name, bytes: file.size),
  ];

  Future<HostFiles?> _open(Host host) async {
    try {
      return await ref.read(hostFilesOpenerProvider)(host);
    } catch (error) {
      if (mounted) setState(() => _status = filesFailureLine(error));
      return null;
    }
  }

  Future<List<String>?> _upload(
    String verb,
    Future<String?> Function(int index, void Function(AttachItem) report) task,
  ) async {
    final items = [for (final file in _shared) AttachItem(bytes: file.size)];
    if (!mounted) return null;
    final job = ref
        .read(transfersProvider)
        .begin(verb: verb, host: _host?.name ?? '', files: _queue);
    setState(() {
      _status = verb;
      _items = items;
    });
    final failures = await runQueue(
      _queue,
      task,
      onItem: (index, item) {
        items[index] = item;
        job.report(index, item);
        if (mounted) setState(() {});
      },
    ).whenComplete(job.end);
    final failed = failures.whereType<String>().length;
    if (failed == 0) return const [];
    if (mounted) setState(() => _status = '$verb · $failed FAILED');
    return null;
  }

  Future<void> _toClipboard(Host host) async {
    setState(() => _busy = true);
    final files = await _open(host);
    if (files == null) return await _done(false);
    try {
      final sharing = uploadsSharing(_shared.length);
      final at = [
        for (final file in _shared)
          remotePathFor('${const Uuid().v4()}/${file.name}'),
      ];
      if (await _upload(
            'UPLOADING',
            (i, report) => pushFile(
              files,
              at[i],
              File(_shared[i].path),
              report,
              sharing: sharing,
            ),
          ) ==
          null) {
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
      setState(
        () => _status = failed == null ? 'COPIED' : 'CLIPBOARD · $failed',
      );
      await _done(failed == null);
    } finally {
      files.close();
    }
  }

  Future<void> _toFolder(Host host) async {
    final folder = await pickHostFolder(context, host);
    if (folder == null || !mounted) return;
    setState(() => _busy = true);
    final files = await _open(host);
    if (files == null) return await _done(false);
    try {
      final taken = {
        for (final entry in await files.list(folder) ?? const <DirEntry>[])
          entry.name,
      };
      String claim(String name) {
        final free = freeName(name, taken);
        taken.add(free);
        return free;
      }

      final names = [for (final file in _shared) claim(file.name)];
      final sharing = uploadsSharing(_shared.length);
      if (await _upload(
            'UPLOADING',
            (i, report) => pushFile(
              files,
              joinPath(folder, names[i]),
              File(_shared[i].path),
              report,
              sharing: sharing,
            ),
          ) ==
          null) {
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
    final hosts = ref.watch(hostsProvider).value ?? const <Host>[];
    final host = _host;
    final text = widget.items.whereType<SharedText>().firstOrNull?.text;
    return PanelSheetBody(
      title: 'SEND TO HOST',
      affordance: PanelAffordance(
        'CANCEL',
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
        if (hosts.isEmpty)
          const EmptyState('no hosts')
        else
          for (final candidate in hosts)
            PickerRow(
              key: ValueKey('send-host-${candidate.id}'),
              label: candidate.name,
              selected: candidate.id == host?.id,
              onTap: () {
                if (!_busy) setState(() => _host = candidate);
              },
            ),
        if (_items.isNotEmpty) ...[
          const SheetRule(),
          TransferQueue(files: _queue, items: _items, keyPrefix: 'send'),
        ],
      ],
    );
  }
}

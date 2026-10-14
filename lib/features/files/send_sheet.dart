import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

const sendSheetLinger = Duration(milliseconds: 700);

Future<void> showSendSheet(
  BuildContext context,
  List<SharedItem> items, {
  int unreadable = 0,
}) => showPanelSheet<void>(
  context,
  title: 'SEND TO HOST',
  builder: (_) => SendSheet(items: items, unreadable: unreadable),
);

class SendSheet extends ConsumerStatefulWidget {
  const SendSheet({super.key, required this.items, this.unreadable = 0});

  final List<SharedItem> items;
  final int unreadable;

  @override
  ConsumerState<SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends ConsumerState<SendSheet> {
  Host? _host;
  String? _status;
  bool _busy = false;
  bool _handed = false;
  TransferJob? _job;
  TransferJob? _pending;
  bool _sent = false;
  Future<void> Function()? _retry;
  ({String host, Map<String, String> sent})? _clipped;
  List<String> _landed = const [];

  late final List<SharedFile> _shared = widget.items
      .whereType<SharedFile>()
      .toList();

  @override
  void dispose() {
    if (!_handed) unawaited(discardCopies(_shared.map((f) => f.path)));
    super.dispose();
  }

  Future<void> _send(
    Host host, {
    String? into,
    required List<SharedFile> files,
    Map<String, String> sent = const {},
  }) {
    final transfers = ref.read(transfersProvider);
    if (_pending case final job?) transfers.drop(job);
    if (_job case final job? when job.ended && job.note != null) {
      transfers.drop(job);
    }
    setState(() {
      _busy = _handed = true;
      _pending = null;
      _retry = null;
      _landed = const [];
      _status = files.isNotEmpty
          ? 'UPLOADING'
          : into == null
          ? 'CLIPBOARD'
          : 'FOLDER';
    });
    return uploadFiles(
      transfers: transfers,
      open: ref.read(hostFilesOpenerProvider),
      host: host,
      files: files,
      into: into,
      sent: sent,
      then: into == null ? _copyTo(widget.items) : _writeTo(widget.items, into),
      began: (job) {
        if (!mounted) return;
        setState(() {
          _busy = _handed = true;
          _job = job;
          _pending = null;
          _retry = null;
          _status = 'UPLOADING';
        });
      },
      ended: (job, sent, failure) => _ended(host, into, job, sent, failure),
    );
  }

  static AfterUpload _copyTo(List<SharedItem> items) => (link, sent, _) async {
    final copied = [
      for (final item in items)
        if (item is! SharedFile || sent.containsKey(item.path)) item,
    ];
    if (copied.isEmpty) return null;
    final landed = [
      for (final item in copied) item is SharedFile ? sent[item.path] : null,
    ];
    final failed = switch (planClipboard(copied, landed)) {
      CopyText(:final text) => await link.copy(text: text),
      CopyImage(:final path, :final mime) => await link.copy(
        imageAt: path,
        mime: mime,
      ),
    };
    return failed == null ? null : 'CLIPBOARD · $failed';
  };

  static AfterUpload _writeTo(List<SharedItem> items, String folder) =>
      (link, _, taken) async {
        final now = DateTime.now();
        for (final text in items.whereType<SharedText>()) {
          final name = freeName(sharedTextName(now), taken!);
          taken.add(name);
          final write = await link.put(
            joinPath(folder, name),
            FileBody.bytes(utf8.encode(text.text)),
          );
          if (write.failure case final failure?) return 'TEXT · $failure';
        }
        return null;
      };

  Future<void> _ended(
    Host host,
    String? into,
    TransferJob? job,
    Map<String, String> sent,
    String? failure,
  ) async {
    final pending = job != null && job.retry != null ? job : null;
    if (!mounted) {
      if (pending == null && failure != null) await discardCopies(sent.keys);
      return;
    }
    final failed = [
      ...?job?.items.where((item) => item.stage == AttachStage.failed),
    ].length;
    if (pending != null) {
      return setState(() {
        _busy = false;
        _pending = pending;
        _status = pending.stop.stopped
            ? 'UPLOADING · STOPPED'
            : 'UPLOADING · $failed FAILED';
        _retry = () => ref.read(transfersProvider).retry(pending);
      });
    }
    if (failure != null) {
      return setState(() {
        _busy = _handed = false;
        _status = failed > 0
            ? 'UPLOADING · $failed FAILED · $failure'
            : failure;
        if (into == null && sent.isNotEmpty) {
          _landed = [...sent.values];
          _clipped = (host: host.id, sent: sent);
        }
        _retry = () => _send(
          host,
          into: into,
          files: [
            for (final file in _shared)
              if (!sent.containsKey(file.path) && File(file.path).existsSync())
                file,
          ],
          sent: sent,
        );
      });
    }
    setState(() {
      _busy = false;
      _sent = true;
      _status = [
        if (sent.isNotEmpty || widget.items.any((item) => item is SharedText))
          into == null ? 'COPIED' : 'IN ${into.split('/').last}',
        if (failed > 0) '$failed FAILED',
        if (widget.unreadable > 0) '${widget.unreadable} UNREADABLE',
      ].join(' · ');
      if (failed > 0 && into == null) _landed = [...sent.values];
    });
    if (failed > 0 || widget.unreadable > 0) return;
    await Future<void>.delayed(sendSheetLinger);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toClipboard(Host host) {
    final reuse = _clipped?.host == host.id
        ? _clipped!.sent
        : const <String, String>{};
    return _send(
      host,
      files: [
        for (final file in _shared)
          if (!reuse.containsKey(file.path)) file,
      ],
      sent: reuse,
    );
  }

  Future<void> _toFolder(Host host) async {
    final folder = await pickHostFolder(context, host);
    if (folder == null || !mounted) return;
    await _send(host, into: folder, files: _shared);
  }

  String _summary() {
    final texts = widget.items.whereType<SharedText>().length;
    final bytes = _shared.fold<int>(0, (sum, file) => sum + file.size);
    return [
      if (_shared.isNotEmpty)
        '${_shared.length} ${_shared.length == 1 ? 'FILE' : 'FILES'} · ${sizeWord(bytes)}',
      if (texts > 0) '$texts ${texts == 1 ? 'TEXT' : 'TEXTS'}',
      if (widget.unreadable > 0) '${widget.unreadable} UNREADABLE',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final loaded = ref.watch(hostsProvider);
    ref.watch(transfersProvider);
    final job = _job;
    final hosts = loaded.value ?? const <Host>[];
    final host = _host ?? (hosts.length == 1 ? hosts.single : null);
    final text = widget.items.whereType<SharedText>().firstOrNull?.text;
    final empty = widget.items.isEmpty;
    return PanelSheetBody(
      title: 'SEND TO HOST',
      affordance: PanelAffordance(
        _job == null && !empty ? 'CANCEL' : 'CLOSE',
        showIcon: false,
        onTap: () => Navigator.of(context).pop(),
      ),
      footer: [
        if (host != null && !_sent && !empty)
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
          if (host != null && !_sent && !empty)
            const SizedBox(height: Spacing.sm),
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
              if (job != null && !job.ended && !job.stop.stopped)
                ActionBlock(
                  key: const ValueKey('send-stop'),
                  label: 'STOP',
                  tone: tokens.danger,
                  onTap: () => ref.read(transfersProvider).stop(job),
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
        if (empty)
          const EmptyState('the app that shared it did not let it be read')
        else if (loaded.isLoading && !loaded.hasValue)
          const Row(children: [DotSpinner()])
        else if (loaded.hasError && !loaded.hasValue)
          Text(
            '${loaded.error}',
            key: const ValueKey('send-hosts-error'),
            style: tokens.label.copyWith(color: tokens.danger),
          )
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
                  _status = null;
                  _job = null;
                });
                if (_pending case final job?) {
                  ref.read(transfersProvider).drop(job);
                  _pending = null;
                  _handed = false;
                }
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
        if (job != null) ...[
          const SheetRule(),
          TransferQueue(files: job.files, items: job.items, keyPrefix: 'send'),
        ],
      ],
    );
  }
}

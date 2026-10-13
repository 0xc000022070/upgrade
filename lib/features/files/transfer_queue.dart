import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/design/components/progress_bar.dart';
import 'package:upgrade/design/components/status_tag.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/shell/input/clip_paste.dart'
    show AttachItem, AttachStage;
import 'package:upgrade/platform/ssh/host_files.dart'
    show TransferStop, atMost, smallestFirst, stoppedFailure, uploadWidth;

export 'package:upgrade/features/shell/input/clip_paste.dart'
    show AttachItem, AttachStage;

typedef QueueTask = Future<String?> Function(
  int index,
  void Function(AttachItem item) report,
  TransferStop? stop,
);

final class QueuedFile {
  const QueuedFile({required this.name, required this.bytes, this.thumb});

  final String name;
  final int bytes;

  final Uint8List? thumb;
}

Future<List<String?>> runQueue(
  List<QueuedFile> files,
  QueueTask task, {
  required void Function(int index, AttachItem item) onItem,
  TransferStop? stop,
}) async {
  final items = [for (final file in files) AttachItem(bytes: file.bytes)];
  void report(int index, AttachItem item) {
    items[index] = item;
    onItem(index, item);
  }

  return Future.wait(
    atMost(
      uploadWidth,
      [
        for (var i = 0; i < files.length; i++)
          () async {
            if (stop?.stopped ?? false) {
              report(i, items[i].to(AttachStage.stopped));
              return stoppedFailure;
            }
            try {
              final failed = await task(i, (item) => report(i, item), stop);
              if (failed == stoppedFailure) {
                report(i, items[i].to(AttachStage.stopped));
              } else if (failed != null) {
                report(i, items[i].to(AttachStage.failed, detail: failed));
              }
              return failed;
            } catch (error) {
              report(i, items[i].to(AttachStage.failed, detail: '$error'));
              return '$error';
            }
          },
      ],
      sizes: [for (final file in files) file.bytes],
    ),
  );
}

class TransferQueue extends StatelessWidget {
  const TransferQueue({
    super.key,
    required this.files,
    required this.items,
    this.keyPrefix = 'transfer',
  });

  final List<QueuedFile> files;
  final List<AttachItem> items;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _QueueCount(items: items, keyPrefix: keyPrefix),
        for (final i in smallestFirst([for (final f in files) f.bytes])) ...[
          const SizedBox(height: Spacing.md),
          _QueueRow(
            key: ValueKey('$keyPrefix-queued-$i'),
            file: files[i],
            item: items[i],
          ),
        ],
      ],
    );
  }
}

class _QueueCount extends StatelessWidget {
  const _QueueCount({required this.items, required this.keyPrefix});

  final List<AttachItem> items;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    int count(Set<AttachStage> stages) =>
        items.where((item) => stages.contains(item.stage)).length;
    final down = items.any((item) => item.down);
    final words = [
      (down ? 'MOVING' : 'UP', count(const {AttachStage.sending})),
      ('QUEUED', count(const {AttachStage.queued})),
      (
        down ? 'DONE' : 'IN',
        count(const {
          AttachStage.landed,
          AttachStage.pasting,
          AttachStage.pasted,
          AttachStage.copied,
          AttachStage.path,
        }),
      ),
    ];
    return Text(
      [for (final (word, n) in words) '$n $word'].join(' · '),
      key: ValueKey('$keyPrefix-queue-count'),
      style: context.tokens.label.copyWith(color: context.tokens.textSecondary),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({super.key, required this.file, required this.item});

  static const _thumb = 44.0;

  final QueuedFile file;
  final AttachItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final (word, color) = switch (item.stage) {
      AttachStage.queued => ('QUEUED', tokens.textMuted),
      AttachStage.sending => (
        '${item.down ? 'DOWN' : 'UP'} ${(item.fraction * 100).floor()}%',
        tokens.accent,
      ),
      AttachStage.landed => ('LANDED', tokens.textSecondary),
      AttachStage.pasting => ('PASTING', tokens.accent),
      AttachStage.pasted => ('PASTED', tokens.accent),
      AttachStage.copied => ('COPIED', tokens.accent),
      AttachStage.path => ('PATH', tokens.accent),
      AttachStage.failed => ('FAILED', tokens.danger),
      AttachStage.stopped => ('STOPPED', tokens.textDisabled),
    };
    final waiting =
        item.stage == AttachStage.queued || item.stage == AttachStage.stopped;
    final detail = item.stage == AttachStage.failed ? item.detail : null;
    final thumb = file.thumb;
    final dot = file.name.lastIndexOf('.');
    final extension = dot <= 0 || file.name.length - dot > 6
        ? 'FILE'
        : file.name.substring(dot + 1).toUpperCase();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: waiting ? 0.4 : 1,
          child: Container(
            width: _thumb,
            height: _thumb,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: item.stage == AttachStage.sending
                    ? color
                    : tokens.borderNormal,
                width: Borders.hairline,
              ),
            ),
            child: thumb != null
                ? Image.memory(
                    thumb,
                    width: _thumb,
                    height: _thumb,
                    fit: BoxFit.cover,
                    cacheWidth: (_thumb * 2).round(),
                    gaplessPlayback: true,
                  )
                : Text(
                    extension,
                    style: tokens.label,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  ),
          ),
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        if (file.name.isNotEmpty) file.name,
                        item.stage == AttachStage.sending
                            ? '${sizeWord(item.sent)} / ${sizeWord(item.bytes)}'
                            : sizeWord(item.bytes),
                      ].join(' · '),
                      style: tokens.value.copyWith(
                        color: waiting ? tokens.textMuted : tokens.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusTag(word, color: color),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              ProgressBar(
                value: switch (item.stage) {
                  AttachStage.queued || AttachStage.stopped => 0,
                  AttachStage.sending || AttachStage.failed => item.fraction,
                  _ => 1,
                },
              ),
              if (detail != null) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  detail,
                  style: tokens.label.copyWith(color: tokens.danger),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

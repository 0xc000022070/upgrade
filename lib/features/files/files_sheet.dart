import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart' show hostsProvider;
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/action_sheet.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/code/file_icons.dart';
import 'package:upgrade/features/code/syntax.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';

Future<void> showHostFiles(BuildContext context, Host host) =>
    showPanelSheet<void>(
      context,
      title: 'FILES',
      builder: (_) => FilesSheet(host: host),
    );

Future<String?> pickHostFolder(BuildContext context, Host host) =>
    showPanelSheet<String>(
      context,
      title: 'PUT HERE',
      builder: (_) => FilesSheet(host: host, picking: true),
    );

Future<Host?> pickHost(
  BuildContext context,
  WidgetRef ref, {
  required String title,
}) async {
  final hosts = await ref.read(hostsProvider.future);
  if (!context.mounted || hosts.isEmpty) return null;
  Host? picked;
  await showActionSheet(
    context,
    title: title,
    recommendFirst: false,
    actions: [
      for (final host in hosts) SheetAction(host.name, () => picked = host),
    ],
  );
  return picked;
}

String joinPath(String directory, String name) =>
    directory == '/' ? '/$name' : '$directory/$name';

Future<void> discardCopies(Iterable<String> paths) async {
  for (final path in paths) {
    try {
      await File(path).parent.delete(recursive: true);
    } catch (_) {
      // ignored: a copy left behind is swept with the cache a day later.
    }
  }
}

Future<String?> pullFile(
  HostFiles from,
  String path,
  File into,
  int size,
  void Function(AttachItem item) report, {
  int sharing = 1,
  TransferStop? stop,
}) async {
  var item = AttachItem(bytes: size, down: true).to(AttachStage.sending);
  report(item);
  final write = await from.get(
    path,
    into,
    size: size,
    sharing: sharing,
    stop: stop,
    onProgress: (sent) =>
        report(item = item.to(AttachStage.sending, sent: sent)),
  );
  if (write.failure != null) return write.failure;
  report(item.to(AttachStage.landed, sent: size));
  return null;
}

Future<String?> pushFile(
  HostFiles to,
  String path,
  File file,
  void Function(AttachItem item) report, {
  int sharing = 1,
  AttachStage done = AttachStage.landed,
  TransferStop? stop,
}) async {
  final size = await file.length();
  var item = AttachItem(bytes: size).to(AttachStage.sending);
  report(item);
  final write = await to.put(
    path,
    FileBody.file(file, size, stop: stop),
    sharing: sharing,
    onProgress: (sent) =>
        report(item = item.to(AttachStage.sending, sent: sent)),
  );
  if (write.failure != null) return write.failure;
  report(item.to(done, sent: size));
  return null;
}

class FilesSheet extends ConsumerStatefulWidget {
  const FilesSheet({super.key, required this.host, this.picking = false});

  final Host host;

  final bool picking;

  @override
  ConsumerState<FilesSheet> createState() => _FilesSheetState();
}

class _FilesSheetState extends ConsumerState<FilesSheet> {
  HostFiles? _files;
  String? _error;
  String? _home;
  String? _target;

  final _listings = <String, List<DirEntry>>{};
  final _failed = <String>{};
  final _open = <String>{};

  String? _status;
  bool _busy = false;
  TransferJob? _job;
  Future<void>? _running;
  List<QueuedFile> _queue = const [];
  List<AttachItem> _items = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  @override
  void dispose() {
    final files = _files;
    if (files != null) {
      unawaited((_running ?? Future<void>.value()).whenComplete(files.close));
    }
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      final files = await ref.read(hostFilesOpenerProvider)(widget.host);
      if (!mounted) {
        files.close();
        return;
      }
      _files = files;
      final home = await files.home();
      if (!mounted) return;
      setState(() {
        _home = home;
        _target = home;
        _open.add(home);
      });
      await _read(home);
    } catch (error) {
      if (mounted) setState(() => _error = filesFailureLine(error));
    }
  }

  Future<void> _read(String directory) async {
    final files = _files;
    if (files == null) return;
    List<DirEntry>? entries;
    try {
      entries = await files.list(directory);
    } catch (_) {
      // ignored: a folder that cannot be listed is drawn as unreadable, whatever the cause.
    }
    if (!mounted) return;
    setState(() {
      if (entries == null) {
        _failed.add(directory);
        _listings.remove(directory);
      } else {
        _failed.remove(directory);
        _listings[directory] = [...entries]..sort(_order);
      }
    });
  }

  static int _order(DirEntry a, DirEntry b) {
    int rank(DirEntry e) =>
        (e.name.startsWith('.') ? 2 : 0) + (e.isDirectory ? 0 : 1);
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0
        ? byRank
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  void _toggle(String directory) {
    setState(() {
      if (widget.picking) _target = directory;
      if (!_open.remove(directory)) _open.add(directory);
    });
    if (_open.contains(directory)) unawaited(_read(directory));
  }

  Future<List<String?>> _run(
    String verb,
    List<QueuedFile> queue,
    QueueTask task,
  ) async {
    final items = [for (final file in queue) AttachItem(bytes: file.bytes)];
    final job = _job = ref
        .read(transfersProvider)
        .begin(verb: verb, host: widget.host.name, files: queue);
    setState(() {
      _busy = true;
      _status = verb;
      _queue = queue;
      _items = items;
    });
    final run = runQueue(
      queue,
      task,
      stop: job.stop,
      onItem: (index, item) {
        items[index] = item;
        job.report(index, item);
        if (mounted) setState(() {});
      },
    ).whenComplete(job.end);
    _running = run;
    final failures = await run;
    final failed = failures
        .where((f) => f != null && f != stoppedFailure)
        .length;
    if (mounted) {
      setState(() {
        _busy = false;
        _status = job.stop.stopped
            ? '$verb · STOPPED'
            : failed == 0
            ? '$verb · DONE'
            : '$verb · $failed FAILED';
      });
    }
    return failures;
  }

  Future<void> _uploadInto(String directory) async {
    final files = _files;
    if (files == null || _busy) return;
    final picked = await ref.read(phoneFilesProvider).pick();
    if (picked.isEmpty || !mounted) return;
    final taken = {
      for (final entry in await files.list(directory) ?? const <DirEntry>[])
        entry.name,
    };
    final names = <String>[];
    for (final file in picked) {
      final name = freeName(file.name, taken);
      taken.add(name);
      names.add(name);
    }
    if (!mounted) return discardCopies(picked.map((f) => f.path));
    final sharing = uploadsSharing(picked.length);
    await _run(
      'UPLOADING',
      [
        for (var i = 0; i < picked.length; i++)
          QueuedFile(name: names[i], bytes: picked[i].size),
      ],
      (i, report, stop) => pushFile(
        files,
        joinPath(directory, names[i]),
        File(picked[i].path),
        report,
        sharing: sharing,
        stop: stop,
      ),
    );
    await discardCopies(picked.map((f) => f.path));
    _open.add(directory);
    await _read(directory);
  }

  Future<void> _share(String path, DirEntry entry) async {
    final files = _files;
    if (files == null || _busy) return;
    final phone = ref.read(phoneFilesProvider);
    final into = File('${(await phone.outgoing()).path}/${entry.name}');
    if (!mounted) return;
    final failures = await _run(
      'SHARING',
      [QueuedFile(name: entry.name, bytes: entry.size)],
      (_, report, stop) =>
          pullFile(files, path, into, entry.size, report, stop: stop),
    );
    if (failures.single == null) await phone.share([into.path]);
  }

  Future<void> _save(String path, DirEntry entry) async {
    final files = _files;
    if (files == null || _busy) return;
    final phone = ref.read(phoneFilesProvider);
    final scratch = await phone.scratch();
    final into = File('${scratch.path}/${entry.name}');
    if (!mounted) return;
    final failures = await _run(
      'SAVING',
      [QueuedFile(name: entry.name, bytes: entry.size)],
      (_, report, stop) =>
          pullFile(files, path, into, entry.size, report, stop: stop),
    );
    String? line;
    if (failures.single == null) {
      try {
        line = await phone.save(into.path, entry.name) ? 'SAVED' : 'NOT SAVED';
      } on PlatformException catch (error) {
        line = 'SAVING · ${error.message ?? error.code}';
      }
    }
    await discardCopies([into.path]);
    if (mounted && line != null) setState(() => _status = line);
  }

  Future<void> _sendToHost(String path, DirEntry entry) async {
    final files = _files;
    if (files == null || _busy) return;
    final target = await pickHost(context, ref, title: 'SEND TO');
    if (target == null || !mounted) return;
    final folder = await pickHostFolder(context, target);
    if (folder == null || !mounted) return;
    final scratch = await ref.read(phoneFilesProvider).scratch();
    final into = File('${scratch.path}/${entry.name}');
    final opener = ref.read(hostFilesOpenerProvider);
    HostFiles? there;
    if (!mounted) return discardCopies([into.path]);
    await _run('SENDING', [QueuedFile(name: entry.name, bytes: entry.size)], (
      _,
      report,
      stop,
    ) async {
      final failed = await pullFile(
        files,
        path,
        into,
        entry.size,
        report,
        stop: stop,
      );
      if (failed != null) return failed;
      final to = there = target.id == widget.host.id
          ? files
          : await opener(target);
      final taken = {
        for (final e in await to.list(folder) ?? const <DirEntry>[]) e.name,
      };
      return pushFile(
        to,
        joinPath(folder, freeName(entry.name, taken)),
        into,
        report,
        stop: stop,
      );
    });
    if (there != null && there != files) there!.close();
    await discardCopies([into.path]);
    if (target.id == widget.host.id) await _read(folder);
  }

  void _directoryActions(String directory) {
    if (widget.picking) {
      Navigator.of(context).pop(directory);
      return;
    }
    unawaited(
      showActionSheet(
        context,
        title: directory == _home ? '~' : directory.split('/').last,
        recommendFirst: false,
        actions: [
          SheetAction('UPLOAD HERE', () => unawaited(_uploadInto(directory))),
          SheetAction('REFRESH', () => unawaited(_read(directory))),
        ],
      ),
    );
  }

  void _fileActions(String path, DirEntry entry) {
    if (widget.picking) return;
    unawaited(
      showActionSheet(
        context,
        title: entry.name,
        recommendFirst: false,
        actions: [
          SheetAction('SHARE', () => unawaited(_share(path, entry))),
          SheetAction('SAVE TO PHONE', () => unawaited(_save(path, entry))),
          SheetAction(
            'SEND TO HOST',
            () => unawaited(_sendToHost(path, entry)),
          ),
        ],
      ),
    );
  }

  static double _indent(int depth) => depth * Spacing.xl;

  Widget _note(String word, int depth) => ListRow(
    title: word,
    leading: const SizedBox.shrink(),
    leadingWidth: _indent(depth) + IconSizes.glyph,
    titleColor: context.tokens.textMuted,
  );

  Widget _directoryRow(String directory, String title, int depth) {
    final open = _open.contains(directory);
    return ListRow(
      key: ValueKey('files-dir-$directory'),
      title: title,
      literalTitle: true,
      leading: Align(
        alignment: Alignment.centerRight,
        child: FileIcon.directory(open: open),
      ),
      leadingWidth: _indent(depth) + IconSizes.glyph,
      node: !open,
      titleColor: widget.picking && directory == _target
          ? context.tokens.accent
          : null,
      onTap: () => _toggle(directory),
      onLongPress: () => _directoryActions(directory),
    );
  }

  void _walk(String directory, int depth, List<Widget> rows) {
    final entries = _listings[directory];
    if (entries == null) {
      rows.add(
        _note(
          _failed.contains(directory) ? 'could not read it' : 'reading…',
          depth,
        ),
      );
      return;
    }
    if (entries.isEmpty) rows.add(_note('empty', depth));
    for (final entry in entries) {
      final path = joinPath(directory, entry.name);
      if (entry.isDirectory) {
        rows.add(_directoryRow(path, entry.name, depth));
        if (_open.contains(path)) _walk(path, depth + 1, rows);
        continue;
      }
      rows.add(
        ListRow(
          key: ValueKey('files-file-$path'),
          title: entry.name,
          literalTitle: true,
          leading: Align(
            alignment: Alignment.centerRight,
            child: FileIcon.file(languageOf(path)),
          ),
          leadingWidth: _indent(depth) + IconSizes.glyph,
          value: sizeWord(entry.size),
          titleColor: widget.picking ? context.tokens.textMuted : null,
          valueColor: widget.picking ? context.tokens.textMuted : null,
          onTap: widget.picking ? null : () => _fileActions(path, entry),
          onLongPress: widget.picking ? null : () => _fileActions(path, entry),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final home = _home;
    final rows = <Widget>[];
    if (home != null) {
      rows.add(_directoryRow(home, '~', 0));
      if (_open.contains(home)) _walk(home, 1, rows);
    }
    final target = _target;
    return PanelSheetBody(
      title: widget.picking ? 'PUT HERE' : 'FILES',
      affordance: PanelAffordance(
        'CLOSE',
        showIcon: false,
        onTap: () => Navigator.of(context).pop(),
      ),
      footer: [
        if (_status case final status?)
          Row(
            children: [
              if (_busy) ...[
                const DotSpinner(),
                const SizedBox(width: Spacing.md),
              ],
              Expanded(
                child: Text(
                  status,
                  key: const ValueKey('files-status'),
                  style: tokens.label,
                ),
              ),
              if (_busy && _job != null && !_job!.stop.stopped)
                ActionBlock(
                  key: const ValueKey('files-stop'),
                  label: 'STOP',
                  tone: tokens.danger,
                  onTap: () => setState(_job!.stop.stop),
                ),
            ],
          ),
        if (widget.picking && target != null) ...[
          Text(
            target == home ? '~' : target,
            key: const ValueKey('files-target'),
            style: tokens.label,
          ),
          const SizedBox(height: Spacing.sm),
          ActionBlock(
            key: const ValueKey('files-put-here'),
            label: 'PUT HERE',
            onTap: () => Navigator.of(context).pop(target),
          ),
        ],
      ],
      children: [
        Text(
          widget.host.name,
          style: tokens.label.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: Spacing.sm),
        if (_error case final error?)
          Text(
            error,
            key: const ValueKey('files-error'),
            style: tokens.label.copyWith(color: tokens.danger),
          )
        else if (home == null)
          const Row(children: [DotSpinner()])
        else
          ...rows,
        if (_queue.isNotEmpty) ...[
          const SheetRule(),
          TransferQueue(files: _queue, items: _items, keyPrefix: 'files'),
        ],
      ],
    );
  }
}

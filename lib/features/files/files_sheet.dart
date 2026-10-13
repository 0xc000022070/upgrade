import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

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
import 'package:upgrade/features/files/transfer_bar.dart' show TransferJobView;
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';
import 'package:upgrade/platform/shell/remote_shell.dart' show remotePathFor;

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

const unreadFolder = 'could not read the folder';

typedef AfterUpload = Future<String?> Function(
  HostFiles link,
  Map<String, String> sent,
  Set<String>? taken,
);

typedef UploadEnded = void Function(
  TransferJob? job,
  Map<String, String> sent,
  String? failure,
);

Future<void> uploadFiles({
  required Transfers transfers,
  required HostFilesOpener open,
  required Host host,
  required List<SharedFile> files,
  String? into,
  Map<String, String> sent = const {},
  AfterUpload? then,
  void Function(TransferJob job)? began,
  UploadEnded? ended,
}) async {
  final job = files.isEmpty
      ? null
      : transfers.begin(
          verb: 'UPLOADING',
          host: host.name,
          files: [
            for (final file in files)
              QueuedFile(name: file.name, bytes: file.size),
          ],
        );
  if (job != null) began?.call(job);
  final landed = {...sent};
  HostFiles? link;
  String? failure;
  var missed = const <SharedFile>[];
  try {
    try {
      link = await open(host);
    } catch (error) {
      failure = filesFailureLine(error);
    }
    Set<String>? taken;
    if (link != null && into != null) {
      final listed = await link.list(into);
      if (listed == null) {
        failure = 'FOLDER · $unreadFolder';
      } else {
        taken = {for (final entry in listed) entry.name};
      }
    }
    final paths = <String>[];
    if (failure == null) {
      for (final file in files) {
        if (taken == null) {
          paths.add(remotePathFor('${const Uuid().v4()}/${file.name}'));
          continue;
        }
        final name = freeName(file.name, taken);
        taken.add(name);
        paths.add(joinPath(into!, name));
      }
    }
    final List<String?> failures;
    if (job == null) {
      failures = const [];
    } else if (failure case final line?) {
      for (var i = 0; i < files.length; i++) {
        job.report(i, job.items[i].to(AttachStage.failed, detail: line));
      }
      failures = List.filled(files.length, line);
    } else {
      final sharing = uploadsSharing(files.length);
      failures = await runQueue(
        job.files,
        (i, report, stop) => pushFile(
          link!,
          paths[i],
          File(files[i].path),
          report,
          sharing: sharing,
          stop: stop,
        ),
        stop: job.stop,
        onItem: job.report,
      );
    }
    for (var i = 0; i < failures.length; i++) {
      if (failures[i] == null) landed[files[i].path] = paths[i];
    }
    missed = [
      for (var i = 0; i < failures.length; i++)
        if (failures[i] != null) files[i],
    ];
    if (job != null && missed.isNotEmpty) {
      job.kept.addAll([...landed.keys, for (final file in missed) file.path]);
      job.retry = () => uploadFiles(
        transfers: transfers,
        open: open,
        host: host,
        files: missed,
        into: into,
        sent: landed,
        then: then,
        began: began,
        ended: ended,
      );
    } else if (failure == null && then != null) {
      failure = await then(link!, landed, taken);
    }
  } finally {
    link?.close();
    job?.end();
  }
  if (missed.isEmpty && (failure == null || ended == null)) {
    await discardCopies(landed.keys);
  }
  ended?.call(job, landed, failure);
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
  final _pulls = <TransferJob>{};
  final _running = <Future<void>>{};

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  @override
  void dispose() {
    for (final job in _pulls) {
      job.retry = null;
    }
    final files = _files;
    unawaited(Future.wait(_running).whenComplete(() => files?.close()));
    super.dispose();
  }

  void _reconnect() {
    _files?.close();
    _files = null;
    setState(() => _error = null);
    unawaited(_connect());
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
      if (_open.remove(directory)) {
        final target = _target;
        if (target != null &&
            directory != _home &&
            (target == directory || target.startsWith('$directory/'))) {
          _target = directory.substring(0, directory.lastIndexOf('/'));
        } else if (directory == _home) {
          _target = directory;
        }
      } else {
        _open.add(directory);
        _target = directory;
      }
      if (widget.picking) _target = directory;
    });
    if (_open.contains(directory)) unawaited(_read(directory));
  }

  Future<List<String?>> _run(
    String verb,
    List<QueuedFile> queue,
    QueueTask task, {
    required Future<void> Function() again,
  }) {
    final job = ref
        .read(transfersProvider)
        .begin(verb: verb, host: widget.host.name, files: queue);
    _pulls.add(job);
    setState(() => _status = null);
    Future<List<String?>> work() async {
      try {
        final failures = await runQueue(
          queue,
          task,
          stop: job.stop,
          onItem: job.report,
        );
        if (mounted && failures.any((f) => f != null)) job.retry = again;
        return failures;
      } finally {
        job.end();
      }
    }

    final run = work();
    _running.add(run);
    return run.whenComplete(() => _running.remove(run));
  }

  Future<void> _uploadInto(String directory) async {
    final picked = await ref.read(phoneFilesProvider).pick();
    if (picked.isEmpty) return;
    if (!mounted) return discardCopies(picked.map((f) => f.path));
    setState(() => _status = null);
    await uploadFiles(
      transfers: ref.read(transfersProvider),
      open: ref.read(hostFilesOpenerProvider),
      host: widget.host,
      files: picked,
      into: directory,
      ended: (_, _, _) {
        if (!mounted) return;
        _open.add(directory);
        unawaited(_read(directory));
      },
    );
  }

  Future<void> _share(String path, DirEntry entry) async {
    final files = _files;
    if (files == null) return;
    final phone = ref.read(phoneFilesProvider);
    final into = File('${(await phone.outgoing()).path}/${entry.name}');
    if (!mounted) return;
    final failures = await _run(
      'SHARING',
      [QueuedFile(name: entry.name, bytes: entry.size)],
      (_, report, stop) =>
          pullFile(files, path, into, entry.size, report, stop: stop),
      again: () => _share(path, entry),
    );
    if (failures.single == null) await phone.share([into.path]);
  }

  Future<void> _save(String path, DirEntry entry) async {
    final files = _files;
    if (files == null) return;
    final phone = ref.read(phoneFilesProvider);
    final scratch = await phone.scratch();
    final into = File('${scratch.path}/${entry.name}');
    if (!mounted) return;
    final failures = await _run(
      'SAVING',
      [QueuedFile(name: entry.name, bytes: entry.size)],
      (_, report, stop) =>
          pullFile(files, path, into, entry.size, report, stop: stop),
      again: () => _save(path, entry),
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

  Future<void> _sendToHost(
    String path,
    DirEntry entry, {
    Host? to,
    String? into,
  }) async {
    final files = _files;
    if (files == null) return;
    final target = to ?? await pickHost(context, ref, title: 'SEND TO');
    if (target == null || !mounted) return;
    final folder = into ?? await pickHostFolder(context, target);
    if (folder == null || !mounted) return;
    final scratch = await ref.read(phoneFilesProvider).scratch();
    final copy = File('${scratch.path}/${entry.name}');
    final opener = ref.read(hostFilesOpenerProvider);
    HostFiles? there;
    if (!mounted) return discardCopies([copy.path]);
    await _run('SENDING', [QueuedFile(name: entry.name, bytes: entry.size)], (
      _,
      report,
      stop,
    ) async {
      final failed = await pullFile(
        files,
        path,
        copy,
        entry.size,
        report,
        stop: stop,
      );
      if (failed != null) return failed;
      final to = there = target.id == widget.host.id
          ? files
          : await opener(target);
      final listed = await to.list(folder);
      if (listed == null) return unreadFolder;
      final taken = {for (final e in listed) e.name};
      return pushFile(
        to,
        joinPath(folder, freeName(entry.name, taken)),
        copy,
        report,
        stop: stop,
      );
    }, again: () => _sendToHost(path, entry, to: target, into: folder));
    if (there != null && there != files) there!.close();
    await discardCopies([copy.path]);
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

  Widget _place(String path, Key key) {
    final tokens = context.tokens;
    final home = _home;
    final shown = path == home
        ? '~'
        : home != null && home != '/' && path.startsWith('$home/')
        ? '~${path.substring(home.length)}'
        : path;
    final slash = shown.lastIndexOf('/');
    return Row(
      key: key,
      children: [
        if (slash >= 0)
          Flexible(
            child: Text(
              shown.substring(0, slash + 1),
              style: tokens.label.copyWith(color: tokens.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Text(shown.substring(slash + 1), style: tokens.label, maxLines: 1),
      ],
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
    final transfers = ref.watch(transfersProvider);
    final mine = [
      for (final job in transfers.jobs)
        if (job.host == widget.host.name) job,
    ];
    final live = [
      for (final job in mine)
        if (!job.ended) job,
    ];
    return PanelSheetBody(
      title: widget.picking ? 'PUT HERE' : 'FILES',
      affordance: PanelAffordance(
        'CLOSE',
        showIcon: false,
        onTap: () => Navigator.of(context).pop(),
      ),
      footer: [
        if (live.isNotEmpty)
          Row(
            children: [
              const DotSpinner(),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  {for (final job in live) job.verb}.join(' · '),
                  key: const ValueKey('files-status'),
                  style: tokens.label,
                ),
              ),
              if (live.any((job) => !job.stop.stopped))
                ActionBlock(
                  key: const ValueKey('files-stop'),
                  label: 'STOP',
                  tone: tokens.danger,
                  onTap: () => live.forEach(transfers.stop),
                ),
            ],
          )
        else if (_status case final status?)
          Text(
            status,
            key: const ValueKey('files-status'),
            style: tokens.label,
          ),
        if ((live.isNotEmpty || _status != null) &&
            target != null &&
            _error == null)
          const SizedBox(height: Spacing.sm),
        if (!widget.picking && target != null && _error == null)
          Row(
            children: [
              Expanded(child: _place(target, const ValueKey('files-target'))),
              ActionBlock(
                key: const ValueKey('files-upload'),
                label: 'UPLOAD',
                onTap: () => unawaited(_uploadInto(target)),
              ),
            ],
          ),
        if (widget.picking && target != null) ...[
          _place(target, const ValueKey('files-target')),
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
        if (_error case final error?) ...[
          Text(
            error,
            key: const ValueKey('files-error'),
            style: tokens.label.copyWith(color: tokens.danger),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              ActionBlock(
                key: const ValueKey('files-reconnect'),
                label: 'RETRY',
                onTap: _reconnect,
              ),
            ],
          ),
        ] else if (home == null)
          const Row(children: [DotSpinner()])
        else
          ...rows,
        for (final (i, job) in mine.indexed) ...[
          const SheetRule(),
          TransferJobView(job: job, keyPrefix: 'files-$i'),
        ],
      ],
    );
  }
}

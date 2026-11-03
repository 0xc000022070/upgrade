import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart'
    show hostsProvider, registeredHostProvider;
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/application/providers.dart';
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
import 'package:upgrade/features/files/host_transfers.dart';
import 'package:upgrade/features/files/transfer_bar.dart' show TransferJobView;
import 'package:upgrade/features/files/transfers.dart';

Future<void> showHostFiles(BuildContext context, Host host) async {
  final transfers = ProviderScope.containerOf(context).read(transfersProvider);
  await showPanelSheet<void>(
    context,
    title: 'FILES',
    builder: (_) => FilesSheet(host: host),
  );
  transfers.seeAll(hostId: host.id);
}

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
  final hosts = await readFirst(ref, hostsProvider.future);
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

class FilesSheet extends ConsumerStatefulWidget {
  const FilesSheet({super.key, required this.host, this.picking = false});

  final Host host;

  final bool picking;

  @override
  ConsumerState<FilesSheet> createState() => _FilesSheetState();
}

class _FilesSheetState extends ConsumerState<FilesSheet> {
  Host get _host =>
      ref.read(registeredHostProvider(widget.host.id)) ?? widget.host;

  HostFiles? _files;
  String? _error;
  String? _home;
  String? _target;

  final _listings = <String, List<DirEntry>>{};
  final _failed = <String>{};
  final _open = <String>{};

  String? _status;
  late final Transfers _transfers;

  @override
  void initState() {
    super.initState();
    _transfers = ref.read(transfersProvider);
    unawaited(_connectOnce());
  }

  @override
  void dispose() {
    _transfers.release(this);
    _files?.close();
    super.dispose();
  }

  Future<void>? _connecting;

  void _reconnect() {
    _files?.close();
    _files = null;
    setState(() => _error = null);
    unawaited(_connectOnce());
  }

  Future<void> _connectOnce() =>
      _connecting ??= _connect().whenComplete(() => _connecting = null);

  Future<void> _connect() async {
    try {
      final files = await ref.read(hostFilesOpenerProvider)(_host);
      if (!mounted) {
        files.close();
        return;
      }
      _files = files;
      if (_home != null) return;
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

  Future<HostFiles?> _live() async {
    if (_files case final files? when files.closed) {
      files.close();
      _files = null;
    }
    if (_files == null && mounted) {
      if (_error != null) setState(() => _error = null);
      await _connectOnce();
    }
    return _files;
  }

  Future<void> _read(String directory) async {
    final files = await _live();
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

  Future<void> _uploadInto(String directory) async {
    final picked = await ref.read(phoneFilesProvider).pick();
    if (picked.isEmpty) return;
    if (!mounted) return discardCopies(picked.map((f) => f.path));
    setState(() => _status = null);
    await _transfers.upload(
      _host,
      picked,
      into: directory,
      ended: (_, _, _) {
        if (!mounted) return;
        _open.add(directory);
        unawaited(_read(directory));
      },
    );
  }

  Future<void> _share(String path, DirEntry entry) {
    final phone = ref.read(phoneFilesProvider);
    setState(() => _status = null);
    return _transfers.pull(
      _host,
      path,
      entry,
      verb: 'SHARING',
      sheet: this,
      into: phone.outgoing,
      keep: true,
      landed: (copy) => phone.share([copy.path]),
    );
  }

  Future<void> _save(String path, DirEntry entry) {
    final phone = ref.read(phoneFilesProvider);
    setState(() => _status = null);
    return _transfers.pull(
      _host,
      path,
      entry,
      verb: 'SAVING',
      sheet: this,
      into: phone.scratch,
      landed: (copy) async {
        String line;
        try {
          line = await phone.save(copy.path, entry.name)
              ? 'SAVED'
              : 'NOT SAVED';
        } on PlatformException catch (error) {
          line = 'SAVING · ${error.message ?? error.code}';
        }
        if (mounted) setState(() => _status = line);
      },
    );
  }

  Future<void> _sendToHost(String path, DirEntry entry) async {
    final target = await pickHost(context, ref, title: 'SEND TO');
    if (target == null || !mounted) return;
    final folder = await pickHostFolder(context, target);
    if (folder == null || !mounted) return;
    setState(() => _status = null);
    await _transfers.pull(
      _host,
      path,
      entry,
      verb: 'SENDING',
      sheet: this,
      into: ref.read(phoneFilesProvider).scratch,
      to: (host: target, folder: folder),
      landed: (_) async {
        if (mounted && target.id == widget.host.id) await _read(folder);
      },
    );
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
    ref.watch(registeredHostProvider(widget.host.id));
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
        if (!widget.picking && job.hostId == widget.host.id) job,
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
          _host.name,
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

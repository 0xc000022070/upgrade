import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/files/host_transfers.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/platform/shell/remote_shell.dart' show remotePathFor;

export 'package:upgrade/platform/ssh/host_files.dart' show TransferStop;

const transferTick = Duration(milliseconds: 500);
const transferRateWindow = Duration(seconds: 3);
const transferLinger = Duration(seconds: 4);

Future<void> discardCopies(Iterable<String> paths) async {
  for (final path in paths) {
    try {
      await File(path).parent.delete(recursive: true);
    } catch (_) {
      // ignored: a copy left behind is swept with the cache a day later.
    }
  }
}

String rateWord(double bytesPerSecond) {
  if (bytesPerSecond < 1024) return '${bytesPerSecond.round()} B/s';
  final k = bytesPerSecond / 1024;
  if (k < 1024) return '${k.round()} K/s';
  final m = k / 1024;
  return '${m < 10 ? m.toStringAsFixed(1) : m.round()} M/s';
}

typedef AfterUpload = Future<String?> Function(
  HostFiles link,
  Map<String, String> sent,
  String Function(String name)? claim,
);

typedef UploadEnded = void Function(
  TransferJob? job,
  Map<String, String> sent,
  String? failure,
);

final class TransferJob {
  TransferJob._(
    this._owner,
    this.verb,
    this.host,
    this.hostId,
    this.files,
    this.stop,
  ) : items = [for (final file in files) AttachItem(bytes: file.bytes)];

  final Transfers _owner;
  final String verb;
  final String host;
  final String? hostId;
  final List<QueuedFile> files;
  final List<AttachItem> items;
  final TransferStop stop;
  DateTime? endedAt;
  bool seen = false;

  Future<void> Function()? _retry;
  Object? _sheet;
  String? note;

  final _kept = <String>[];

  bool get ended => endedAt != null;

  bool get retryable => _retry != null;

  bool get retrying => _owner._retrying.contains(this);

  bool get failed =>
      note != null || items.any((item) => item.stage == AttachStage.failed);

  void report(int index, AttachItem item) {
    final before = items[index].sent;
    items[index] = item;
    if (item.sent > before) _owner._moved += item.sent - before;
    _owner._dirty = true;
  }

  void end() {
    if (ended) return;
    for (var i = 0; i < items.length; i++) {
      if (items[i].stage case AttachStage.queued || AttachStage.sending) {
        items[i] = items[i].to(AttachStage.stopped);
      }
    }
    endedAt = _owner._now();
    _owner._ended(this);
  }
}

final class TransferTally {
  const TransferTally({
    required this.up,
    required this.down,
    required this.queued,
    required this.sent,
    required this.bytes,
    required this.rate,
  });

  final int up;
  final int down;
  final int queued;
  final int sent;
  final int bytes;
  final double rate;

  int get percent => bytes == 0 ? 0 : (sent * 100 ~/ bytes).clamp(0, 100);

  String get counts => [
    if (up > 0) 'UP $up',
    if (down > 0) 'DOWN $down',
    if (queued > 0) 'QUEUED $queued',
  ].join(' · ');
}

class Transfers extends ChangeNotifier {
  Transfers({required this._open, this.status, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final HostFilesOpener _open;
  final TransferStatus? status;
  final DateTime Function() _now;

  final _jobs = <TransferJob>[];
  final _sheets = <Object>{};
  final _retrying = <TransferJob>{};

  final _sending = <String, Set<String>>{};
  final _samples = <(DateTime, int)>[];
  int _moved = 0;
  bool _dirty = false;
  Timer? _ticker;
  int _ticks = 0;
  int _failed = 0;
  int _landed = 0;
  int _stopped = 0;

  List<TransferJob> get jobs => List.unmodifiable(_jobs);

  bool get active => _jobs.any((job) => !job.ended);

  String _claim(String hostId, String folder, String name, Set<String> taken) {
    final sending = _sending.putIfAbsent(hostId, () => {});
    final free = freeName(name, {
      ...taken,
      for (final path in sending)
        if (joinPath(folder, path.split('/').last) == path)
          path.split('/').last,
    });
    taken.add(free);
    sending.add(joinPath(folder, free));
    return joinPath(folder, free);
  }

  void _unclaim(String hostId, Iterable<String> paths) {
    final sending = _sending[hostId];
    if (sending == null) return;
    sending.removeAll(paths);
    if (sending.isEmpty) _sending.remove(hostId);
  }

  void stop(TransferJob job) {
    job.stop.stop();
    notifyListeners();
  }

  void drop(TransferJob job) {
    job._retry = null;
    job._kept.clear();
    if (_jobs.remove(job)) notifyListeners();
  }

  void dismiss(TransferJob job) {
    unawaited(discardCopies(job._kept));
    drop(job);
  }

  void release(Object sheet) {
    _sheets.remove(sheet);
    for (final job in _jobs) {
      if (job._sheet == sheet) job._retry = null;
    }
    _ticker ??= Timer.periodic(transferTick, (_) => _tick());
  }

  Future<void> retry(TransferJob job) {
    final again = job._retry;
    if (again == null) return Future.value();
    job._retry = null;
    job._kept.clear();
    _retrying.add(job);
    notifyListeners();
    return again().whenComplete(() {
      _retrying.remove(job);
      job._retry == null ? drop(job) : notifyListeners();
    });
  }

  Future<void> upload(
    Host host,
    List<SharedFile> files, {
    String? into,
    Map<String, String> sent = const {},
    AfterUpload? then,
    void Function(TransferJob job)? began,
    UploadEnded? ended,
  }) {
    Future<void> attempt(
      List<SharedFile> files,
      Map<String, String> sent,
      TransferJob? replacing,
    ) async {
      final job = files.isEmpty
          ? null
          : begin(
              verb: 'UPLOADING',
              host: host.name,
              hostId: host.id,
              files: [
                for (final file in files)
                  QueuedFile(name: file.name, bytes: file.size),
              ],
              replacing: replacing,
            );
      if (job != null) began?.call(job);
      final landed = {...sent};
      HostFiles? link;
      String? failure;
      var missed = const <SharedFile>[];
      final paths = <String>[];
      try {
        try {
          link = await _open(host);
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
        if (failure == null) {
          for (final file in files) {
            if (taken == null) {
              paths.add(remotePathFor('${const Uuid().v4()}/${file.name}'));
              continue;
            }
            paths.add(_claim(host.id, into!, file.name, taken));
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
            (i, report, stop) async {
              final copy = File(files[i].path);
              if (!await copy.exists()) return copyGone;
              return pushFile(
                link!,
                paths[i],
                copy,
                report,
                sharing: sharing,
                stop: stop,
              );
            },
            stop: job.stop,
            onItem: job.report,
          );
        }
        for (var i = 0; i < failures.length; i++) {
          if (failures[i] == null) landed[files[i].path] = paths[i];
        }
        missed = [
          for (var i = 0; i < failures.length; i++)
            if (failures[i] != null && failures[i] != copyGone) files[i],
        ];
        if (job != null && missed.isNotEmpty) {
          job._kept.addAll([
            ...landed.keys,
            for (final file in missed) file.path,
          ]);
          job._retry = () => attempt(missed, landed, job);
        } else if (failure == null && then != null) {
          String claim(String name) {
            final path = _claim(host.id, into!, name, taken!);
            paths.add(path);
            return path;
          }

          failure = await then(link!, landed, taken == null ? null : claim);
          if (job != null && failure != null) {
            job.note = [failure, if (into == null) ...landed.values].join('\n');
          }
        }
      } finally {
        if (into != null) _unclaim(host.id, paths);
        link?.close();
        job?.end();
      }
      if (missed.isEmpty && (failure == null || ended == null)) {
        await discardCopies(landed.keys);
      }
      ended?.call(job, landed, failure);
    }

    return attempt(files, sent, null);
  }

  Future<void> pull(
    Host host,
    String path,
    DirEntry entry, {
    required String verb,
    required Object sheet,
    required Future<Directory> Function() into,
    ({Host host, String folder})? to,
    bool keep = false,
    Future<void> Function(File copy)? landed,
  }) {
    _sheets.add(sheet);
    Future<void> attempt(TransferJob? replacing) async {
      HostFiles? from;
      String? unreached;
      try {
        from = await _open(host);
      } catch (error) {
        unreached = filesFailureLine(error);
      }
      if (replacing != null && unreached != null) {
        if (_sheets.contains(sheet)) {
          replacing._retry = () => attempt(replacing);
        }
        return;
      }
      final job = begin(
        verb: verb,
        host: host.name,
        hostId: host.id,
        files: [QueuedFile(name: entry.name, bytes: entry.size)],
        replacing: replacing,
      ).._sheet = sheet;
      HostFiles? there;
      File? copy;
      final String? failed;
      try {
        failed = (await runQueue(
          job.files,
          (_, report, stop) async {
            final link = from;
            if (link == null) return unreached;
            final file = copy = File('${(await into()).path}/${entry.name}');
            final failed = await pullFile(
              link,
              path,
              file,
              entry.size,
              report,
              stop: stop,
            );
            if (failed != null || to == null) return failed;
            final target = there = to.host.id == host.id
                ? link
                : await _open(to.host);
            final listed = await target.list(to.folder);
            if (listed == null) return unreadFolder;
            final taken = {for (final e in listed) e.name};
            final put = _claim(to.host.id, to.folder, entry.name, taken);
            try {
              return await pushFile(target, put, file, report, stop: stop);
            } finally {
              _unclaim(to.host.id, [put]);
            }
          },
          stop: job.stop,
          onItem: job.report,
        )).single;
        if (failed != null && _sheets.contains(sheet)) {
          job._retry = () => attempt(job);
        }
      } finally {
        if (there != from) there?.close();
        from?.close();
        job.end();
      }
      final file = copy;
      if (file == null) return;
      if (failed == null) await landed?.call(file);
      if (failed != null || !keep) await discardCopies([file.path]);
    }

    return attempt(null);
  }

  void stopAll() {
    for (final job in _jobs) {
      if (!job.ended) job.stop.stop();
    }
  }

  void seeAll({String? hostId}) {
    var changed = false;
    for (final job in _jobs) {
      if (job.ended && !job.seen && (hostId == null || job.hostId == hostId)) {
        job.seen = changed = true;
        job.endedAt = _now();
      }
    }
    if (!changed) return;
    _ticker ??= Timer.periodic(transferTick, (_) => _tick());
    notifyListeners();
  }

  TransferJob begin({
    required String verb,
    required String host,
    String? hostId,
    required List<QueuedFile> files,
    TransferStop? stop,
    TransferJob? replacing,
  }) {
    final job = TransferJob._(
      this,
      verb,
      host,
      hostId,
      files,
      stop ?? TransferStop(),
    );
    final at = replacing == null ? -1 : _jobs.indexOf(replacing);
    at < 0 ? _jobs.add(job) : _jobs[at] = job;
    _ticker ??= Timer.periodic(transferTick, (_) => _tick());
    _sample();
    notifyListeners();
    _post();
    return job;
  }

  TransferTally get tally {
    var up = 0, down = 0, queued = 0, sent = 0, bytes = 0;
    for (final job in _jobs) {
      if (job.ended) continue;
      for (final item in job.items) {
        switch (item.stage) {
          case AttachStage.queued:
            queued++;
          case AttachStage.sending:
            item.down ? down++ : up++;
          default:
        }
        sent += item.sent;
        bytes += item.bytes;
      }
    }
    return TransferTally(
      up: up,
      down: down,
      queued: queued,
      sent: sent,
      bytes: bytes,
      rate: _rate(),
    );
  }

  double _rate() {
    if (_samples.length < 2) return 0;
    final (from, fromMoved) = _samples.first;
    final (to, toMoved) = _samples.last;
    final seconds = to.difference(from).inMicroseconds / 1e6;
    return seconds <= 0 ? 0 : (toMoved - fromMoved) / seconds;
  }

  void _sample() {
    final now = _now();
    _samples.add((now, _moved));
    while (_samples.length > 2 &&
        now.difference(_samples.first.$1) > transferRateWindow) {
      _samples.removeAt(0);
    }
  }

  void _tick() {
    _sample();
    final now = _now();
    final gone = [
      for (final job in _jobs)
        if (job.ended &&
            job._retry == null &&
            !_retrying.contains(job) &&
            (job.seen || !job.failed) &&
            now.difference(job.endedAt!) >= transferLinger)
          job,
    ];
    for (final job in gone) {
      _jobs.remove(job);
      unawaited(discardCopies(job._kept));
    }
    if (_dirty || gone.isNotEmpty) {
      _dirty = false;
      notifyListeners();
    }
    if ((++_ticks).isEven && active) _post();
    if (!active &&
        _jobs.every((job) => job._retry != null || (job.failed && !job.seen))) {
      _ticker?.cancel();
      _ticker = null;
      _samples.clear();
    }
  }

  void _ended(TransferJob job) {
    for (final item in job.items) {
      switch (item.stage) {
        case AttachStage.failed:
          _failed++;
        case AttachStage.stopped:
          _stopped++;
        default:
          _landed++;
      }
    }
    notifyListeners();
    if (active) return _post();
    status?.done(
      [
        if (_landed > 0) 'MOVED $_landed',
        if (_failed > 0) '$_failed FAILED',
        if (_stopped > 0) '$_stopped STOPPED',
      ].join(' · '),
    );
    _failed = 0;
    _stopped = 0;
    _landed = 0;
  }

  void _post() {
    final tally = this.tally;
    status?.moving(
      [
        if (tally.counts.isNotEmpty) tally.counts,
        '${tally.percent}%',
      ].join(' · '),
      '${rateWord(tally.rate)} · ${sizeWord(tally.sent)} of ${sizeWord(tally.bytes)}',
      tally.percent,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

final transfersProvider = ChangeNotifierProvider<Transfers>((ref) {
  final phone = ref.read(phoneFilesProvider);
  final transfers = Transfers(
    open: (host) => ref.read(hostFilesOpenerProvider)(host),
    status: phone,
  );
  final stops = phone.stops.listen((_) => transfers.stopAll());
  ref.onDispose(stops.cancel);
  return transfers;
});

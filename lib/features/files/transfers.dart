import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/platform/ssh/host_files.dart' show TransferStop;

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

  Future<void> Function()? retry;
  String? note;

  final kept = <String>[];

  bool get ended => endedAt != null;

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
  Transfers({this.status, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final TransferStatus? status;
  final DateTime Function() _now;

  final _jobs = <TransferJob>[];
  final _samples = <(DateTime, int)>[];
  int _moved = 0;
  bool _dirty = false;
  Timer? _ticker;
  int _ticks = 0;
  int _failed = 0;
  int _landed = 0;
  int _stopped = 0;
  int? _slot;

  List<TransferJob> get jobs => List.unmodifiable(_jobs);

  bool get active => _jobs.any((job) => !job.ended);

  void stop(TransferJob job) {
    job.stop.stop();
    notifyListeners();
  }

  void drop(TransferJob job) {
    job.retry = null;
    job.kept.clear();
    if (_jobs.remove(job)) notifyListeners();
  }

  void dismiss(TransferJob job) {
    unawaited(discardCopies(job.kept));
    drop(job);
  }

  void release(TransferJob job) {
    if (job.retry == null) return;
    job.retry = null;
    _ticker ??= Timer.periodic(transferTick, (_) => _tick());
  }

  Future<void> retry(TransferJob job) {
    final again = job.retry;
    if (again == null) return Future.value();
    final slot = _jobs.indexOf(job);
    drop(job);
    _slot = slot;
    return again().whenComplete(() {
      if (_slot == slot) _slot = null;
    });
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
  }) {
    final job = TransferJob._(
      this,
      verb,
      host,
      hostId,
      files,
      stop ?? TransferStop(),
    );
    final slot = _slot;
    _slot = null;
    slot != null && slot <= _jobs.length
        ? _jobs.insert(slot, job)
        : _jobs.add(job);
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
            job.retry == null &&
            (job.seen || !job.failed) &&
            now.difference(job.endedAt!) >= transferLinger)
          job,
    ];
    for (final job in gone) {
      _jobs.remove(job);
      unawaited(discardCopies(job.kept));
    }
    if (_dirty || gone.isNotEmpty) {
      _dirty = false;
      notifyListeners();
    }
    if ((++_ticks).isEven && active) _post();
    if (!active &&
        _jobs.every((job) => job.retry != null || (job.failed && !job.seen))) {
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
  final transfers = Transfers(status: phone);
  final stops = phone.stops.listen((_) => transfers.stopAll());
  ref.onDispose(stops.cancel);
  return transfers;
});

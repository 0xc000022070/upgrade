import 'dart:async';

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

String rateWord(double bytesPerSecond) {
  if (bytesPerSecond < 1024) return '${bytesPerSecond.round()} B/s';
  final k = bytesPerSecond / 1024;
  if (k < 1024) return '${k.round()} K/s';
  final m = k / 1024;
  return '${m < 10 ? m.toStringAsFixed(1) : m.round()} M/s';
}

final class TransferJob {
  TransferJob._(this._owner, this.verb, this.host, this.files, this.stop)
    : items = [for (final file in files) AttachItem(bytes: file.bytes)];

  final Transfers _owner;
  final String verb;
  final String host;
  final List<QueuedFile> files;
  final List<AttachItem> items;
  final TransferStop stop;
  DateTime? endedAt;
  bool seen = false;

  bool get ended => endedAt != null;

  bool get failed => items.any((item) => item.stage == AttachStage.failed);

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
    if (queued > 0) '$queued QUEUED',
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

  List<TransferJob> get jobs => List.unmodifiable(_jobs);

  bool get active => _jobs.any((job) => !job.ended);

  void stopAll() {
    for (final job in _jobs) {
      if (!job.ended) job.stop.stop();
    }
  }

  void seeAll() {
    var changed = false;
    for (final job in _jobs) {
      if (job.ended && !job.seen) {
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
    required List<QueuedFile> files,
    TransferStop? stop,
  }) {
    final job = TransferJob._(this, verb, host, files, stop ?? TransferStop());
    _jobs.add(job);
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
    final before = _jobs.length;
    _jobs.removeWhere(
      (job) =>
          job.ended &&
          (job.seen || !job.failed) &&
          now.difference(job.endedAt!) >= transferLinger,
    );
    if (_dirty || before != _jobs.length) {
      _dirty = false;
      notifyListeners();
    }
    if ((++_ticks).isEven && active) _post();
    if (!active && _jobs.every((job) => job.failed && !job.seen)) {
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

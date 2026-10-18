import 'dart:async';

import 'package:striked/platform/shell/shell_connection.dart';

final class LivenessWatchdog {
  LivenessWatchdog({
    required this.interval,
    required this.giveUp,
    required this.probing,
    required this.probe,
    required this.onSilent,
    this.probeOnMiss = false,
  });

  final Duration interval;
  final Duration giveUp;
  final bool Function() probing;
  final void Function() probe;
  final void Function() onSilent;
  final bool probeOnMiss;

  final _ticking = Stopwatch()..start();
  Timer? _timer;
  int? _tickedAt;
  var _missed = 0;
  var _health = ShellConnectionHealth.connected;

  late final StreamController<ShellConnectionHealth> _events =
      StreamController<ShellConnectionHealth>.broadcast(
        onListen: () => scheduleMicrotask(() {
          if (!_events.isClosed) _events.add(_health);
        }),
      );

  Stream<ShellConnectionHealth> get health => _events.stream;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void forget() {
    _missed = 0;
    _tickedAt = null;
  }

  void heard() {
    _missed = 0;
    report(ShellConnectionHealth.connected);
  }

  void report(ShellConnectionHealth health) {
    if (_health == health) return;
    _health = health;
    if (!_events.isClosed) _events.add(health);
  }

  Future<void> close() => _events.close();

  int get _probesToGiveUp {
    final probes = giveUp.inMicroseconds ~/ interval.inMicroseconds;
    return probes < 3 ? 3 : probes;
  }

  void _check() {
    final now = _ticking.elapsedMicroseconds;
    final previous = _tickedAt;
    _tickedAt = now;
    if (!probing()) {
      probe();
      return;
    }
    // A process Android froze fires every tick it owed the moment it thaws, back to
    // back: that run is one gap in the link and not one missed answer each.
    if (previous != null && now - previous < interval.inMicroseconds ~/ 2) {
      return;
    }
    _missed++;
    if (probeOnMiss) probe();
    if (_missed >= _probesToGiveUp) {
      stop();
      onSilent();
      return;
    }
    report(
      _missed >= 3
          ? ShellConnectionHealth.disconnected
          : ShellConnectionHealth.reconnecting,
    );
  }
}

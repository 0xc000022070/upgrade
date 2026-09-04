import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/host_repository.dart';
import '../../platform/link_probe.dart';

/// The transport seam, injectable so the panel can be driven without a machine
/// answering. The real one is [probeLink].
typedef LinkProbe = Future<LinkResult> Function(String address, int port);

/// How long a probe's answer stands. HOSTS coming to the front reprobes
/// anything older; a tap on the row reprobes whatever its age.
const linkProbeMaxAge = Duration(seconds: 30);

/// What every host last said, for the app's life.
///
/// A [ChangeNotifier] rather than a family of futures: the panel redraws one
/// row when one host answers, and a provider per host would restart every
/// probe each time the hosts list rebuilt.
class LinkProbes extends ChangeNotifier {
  LinkProbes({LinkProbe? probe, DateTime Function()? now})
    : _probe = probe ?? probeLink,
      _now = now ?? DateTime.now;

  final LinkProbe _probe;
  final DateTime Function() _now;

  final _results = <String, LinkResult>{};
  final _probedAt = <String, DateTime>{};

  /// Hosts with a probe in flight. Two callers landing on the same host — the
  /// screen coming forward and a tap on the row — must not put two connections
  /// on it.
  final _inFlight = <String>{};

  LinkResult forHost(String hostId) =>
      _results[hostId] ?? const LinkResult.unknown();

  /// Every host at once. Sequential probes would make the panel's first draw
  /// the sum of the hosts' deadlines.
  Future<void> refresh(List<Host> hosts) =>
      Future.wait(hosts.map(probe)).then((_) {});

  Future<void> probe(Host host, {bool force = false}) async {
    if (_inFlight.contains(host.id)) return;
    if (!force) {
      final last = _probedAt[host.id];
      if (last != null && _now().difference(last) < linkProbeMaxAge) return;
    }
    _inFlight.add(host.id);
    _results[host.id] = const LinkResult.probing();
    notifyListeners();
    try {
      _results[host.id] = await _probe(host.address, host.port);
    } finally {
      _inFlight.remove(host.id);
      // Stamped on the way out, so a probe that took its whole deadline is not
      // already stale by the time it answers.
      _probedAt[host.id] = _now();
      notifyListeners();
    }
  }
}

final linkProbesProvider = Provider<LinkProbes>((ref) {
  ref.keepAlive();
  return LinkProbes();
});

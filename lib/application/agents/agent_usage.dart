import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';

typedef HostUsage = ({Host host, AgentUsage usage});

const usagePoll = Duration(minutes: 1);

final homeUsageVisibleProvider = StateProvider<bool>((ref) => false);

class UsageFeed extends Notifier<List<HostUsage>> {
  final _byHost = <String, List<AgentUsage>>{};
  final _unreached = <String, String>{};
  final _reading = <String>{};
  final _queued = <String>{};
  final _unsupported = <String>{};
  final _misses = <String, int>{};
  final _restUntil = <String, DateTime>{};
  var _hosts = const <Host>[];
  var _live = false;
  int? _wake;

  @override
  List<HostUsage> build() {
    _live = true;
    ref.onDispose(() => _live = false);
    _hosts = ref.watch(engineHostsProvider).value ?? const [];
    bool gone(String id) => _hosts.every((host) => host.id != id);
    for (final known in [_byHost, _unreached, _misses, _restUntil]) {
      known.removeWhere((id, _) => gone(id));
    }
    _unsupported.removeWhere(gone);
    final wake = ref.watch(agentsWakeProvider);
    if (wake != _wake) {
      _wake = wake;
      _misses.clear();
      _restUntil.clear();
      _unsupported.clear();
    }
    final watched =
        ref.watch(homeUsageVisibleProvider) && ref.watch(appVisibleProvider);
    if (watched && _hosts.isNotEmpty) {
      final timer = Timer.periodic(usagePoll, (_) => unawaited(refresh()));
      ref.onDispose(timer.cancel);
      Future.microtask(refresh);
    }
    return _flatten();
  }

  Future<void> refresh({bool fresh = false}) async {
    if (!_live) return;
    final open = ref.read(engineOpenProvider);
    final now = DateTime.now();
    final reads = <Future<void>>[];
    for (final host in _hosts) {
      if (_reading.contains(host.id)) {
        if (fresh) _queued.add(host.id);
        continue;
      }
      final resting =
          _unsupported.contains(host.id) ||
          (_restUntil[host.id]?.isAfter(now) ?? false);
      if (fresh || !resting) reads.add(_read(open, host, fresh: fresh));
    }
    await Future.wait(reads);
  }

  Future<void> _read(EngineOpen open, Host host, {required bool fresh}) async {
    _reading.add(host.id);
    try {
      final engine = await open(host);
      try {
        _byHost[host.id] = await engine.usage(fresh: fresh);
      } finally {
        engine.session.close();
      }
      _unreached.remove(host.id);
      _unsupported.remove(host.id);
      _misses.remove(host.id);
      _restUntil.remove(host.id);
    } on EngineRefused catch (error) {
      if (error.kind == 'unsupported') {
        _byHost.remove(host.id);
        _unreached.remove(host.id);
        _unsupported.add(host.id);
      } else {
        debugPrint('upgrade.usage ${host.name}: $error');
        _unreached[host.id] = error.message;
      }
    } catch (error) {
      debugPrint('upgrade.usage ${host.name}: $error');
      _unreached[host.id] = 'NOT REACHED';
      final misses = (_misses[host.id] ?? 0) + 1;
      _misses[host.id] = misses;
      _restUntil[host.id] = DateTime.now().add(
        usagePoll * (1 << misses.clamp(1, 4)) - _tickSlack,
      );
    } finally {
      _reading.remove(host.id);
    }
    if (!_live || _hosts.every((known) => known.id != host.id)) return;
    state = _flatten();
    if (_queued.remove(host.id)) {
      await _read(ref.read(engineOpenProvider), host, fresh: true);
    }
  }

  List<HostUsage> _flatten() => [
    for (final host in _hosts)
      for (final usage in _byHost[host.id] ?? const <AgentUsage>[])
        (
          host: host,
          usage: switch (_unreached[host.id]) {
            final reason? => usage.failing(reason),
            null => usage,
          },
        ),
  ];
}

const _tickSlack = Duration(seconds: 5);

final usageFeedProvider =
    NotifierProvider.autoDispose<UsageFeed, List<HostUsage>>(UsageFeed.new);

typedef UsageDays = ({DateTime day, double? today, double? yesterday});

double? usageRise(List<UsageSample> history, DateTime from, DateTime to) {
  if (history.isEmpty || !history.first.at.isBefore(to)) return null;
  var rise = 0.0;
  for (var i = 1; i < history.length; i++) {
    final (before, after) = (history[i - 1], history[i]);
    if (after.at.isBefore(from) || !after.at.isBefore(to)) continue;
    rise += _restarted(before, after)
        ? after.usedPercent
        : math.max(0, after.usedPercent - before.usedPercent);
  }
  return rise;
}

// A reset time that drifts between reads is not a new window: one began only
// if the share fell or the earlier window's reset has come.
bool _restarted(UsageSample before, UsageSample after) =>
    after.resetsAt != before.resetsAt &&
    (after.usedPercent < before.usedPercent ||
        switch (before.resetsAt) {
          final resets? => !after.at.isBefore(resets),
          null => true,
        });

UsageDays usageDays(AgentUsage usage, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  final before = DateTime(now.year, now.month, now.day - 1);
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  return (
    day: day,
    today: usageRise(usage.history, day, tomorrow),
    yesterday: usageRise(usage.history, before, day),
  );
}

List<AgentUsage> usageAccounts(List<HostUsage> usages) {
  final accounts = <(String, String?, String?), AgentUsage>{};
  for (final (host: _, :usage) in usages) {
    final key = (usage.agent, usage.account, usage.plan);
    final kept = accounts[key];
    if (kept == null || _fresher(usage, kept)) accounts[key] = usage;
  }
  return [...accounts.values];
}

bool _fresher(AgentUsage usage, AgentUsage than) {
  final (at, other) = (usage.captured, than.captured);
  if (at == null || other == null) return other == null && at != null;
  if (at != other) return at.isAfter(other);
  return usage.error == null && than.error != null;
}

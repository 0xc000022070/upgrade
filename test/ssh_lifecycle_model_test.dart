import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';

import 'support/host_links.dart';
import 'support/reasons.dart';
import 'support/ssh_exec.dart';

const _seeds = [1, 2, 3, 5, 8, 13, 21, 34];
const _steps = 300;

final _vm = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:vm',
  pinnedAt: DateTime(2026),
);

const _address = '10.0.0.2';
const _port = 22;
const _user = 'dev';
const _privateKey = 'key';

const _connectorTimeout = Duration(seconds: 10);

enum _Outcome { land, fail, settle, slow }

enum _Kind { establish, open, lease, exec }

final class _Op {
  _Op(this.kind, this.issued, {this.tab, this.reason, this.use});

  final _Kind kind;
  final int issued;
  final _Tab? tab;
  final String? reason;
  final HostUse? use;
  var done = false;
  int? doneStep;
  Object? error;
}

final class _Tab {
  _Tab(this.id, this.sup, this.revives, this.createdStep);

  final int id;
  final ConnectionSupervisor sup;
  final bool revives;
  final int createdStep;
  var retired = false;
  var suspended = false;
  var claimed = false;
  var blockedAt = -1;
  var retiredAt = -1;
  var droppedTick = -1;
  var reviveArmed = false;
  var streamDone = false;
  FakeLinkClient? held;
}

final class _Handed {
  _Handed(this.tab, this.channels, this.tick, {required this.mustBeNull});

  final _Tab tab;
  final HostChannels channels;
  final int tick;
  final bool mustBeNull;
  FakeLinkClient? client;
  var nulled = false;
}

final class _Mine {
  _Mine(this.lease);

  final HostLease lease;
  var released = false;
}

final class _Dial {
  _Dial(this.step, this.causes);

  final int step;
  final List<String> causes;
}

final class _Model {
  _Model(this.tester, this.seed) : rng = Random(seed) {
    links = HostLinks(dial: _dial, now: () => tester.binding.clock.now());
    connector = SshConnector(links: links, timeout: _connectorTimeout);
  }

  final WidgetTester tester;
  final int seed;
  final Random rng;
  late final HostLinks links;
  late final SshConnector connector;

  var step = 0;
  var tick = 0;
  var advancing = false;
  var asleep = false;
  var screenUsed = false;

  final queue = <_Outcome>[];
  final dials = <_Dial>[];
  final clients = <FakeLinkClient>[];
  final gates = <Completer<void>>[];
  final settles = <Completer<void>>[];

  final tabs = <_Tab>[];
  final ops = <_Op>[];
  final handed = <_Handed>[];
  final mine = <_Mine>[];
  final reconnects = <Reconnect>[];
  final trace = <String>[];
  final violations = <String>[];

  var _tabs = 0;
  var _probes = 0;

  void violate(String what) => violations.add('seed $seed step $step: $what');

  void log(String event) {
    trace.add('$step: $event');
    if (trace.length > 40) trace.removeAt(0);
  }

  Future<SshLink> _dial({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
    void Function(Future<void> settled)? onSettling,
  }) async {
    final causes = _causes();
    dials.add(_Dial(step, causes));
    if (causes.isEmpty) {
      violate('a dial started with no open, reopen or revive behind it');
    }
    final outcome = queue.isEmpty ? _Outcome.land : queue.removeAt(0);
    switch (outcome) {
      case _Outcome.land:
        break;
      case _Outcome.fail:
        throw const SocketException('Connection refused');
      case _Outcome.settle:
        final settle = Completer<void>();
        settles.add(settle);
        onSettling?.call(settle.future);
        throw TimeoutException('login', _connectorTimeout);
      case _Outcome.slow:
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
    }
    final client = FakeLinkClient()
      ..reply = (_) => (exitCode: 0, stdout: '', stderr: '');
    clients.add(client);
    return (
      socket: FakeExecSocket(),
      client: client,
      received: () => client.received,
    );
  }

  List<String> _causes() => [
    for (final op in ops)
      if (!op.done) ?_dialsFor(op),
    if (advancing)
      for (final tab in tabs)
        if (tab.revives && tab.reviveArmed && !tab.retired && !tab.suspended)
          'revive of tab ${tab.id}',
  ];

  String? _dialsFor(_Op op) => switch (op.kind) {
    _Kind.establish => 'establish',
    _Kind.exec => 'exec overflow',
    _Kind.lease => op.use!.wakes || !asleep ? 'lease ${op.use!.label}' : null,
    _Kind.open => _opens(op) ? 'open ${op.reason} on tab ${op.tab!.id}' : null,
  };

  bool _opens(_Op op) {
    final tab = op.tab!;
    if (tab.retired) return false;
    if (tab.suspended) return op.reason == 'UserAction';
    return true;
  }

  Future<T?> _track<T>(
    _Op op,
    Future<T> Function() start, [
    void Function(T)? landed,
  ]) {
    ops.add(op);
    return start().then<T?>(
      (value) {
        op
          ..done = true
          ..doneStep = step;
        landed?.call(value);
        return value;
      },
      onError: (Object error) {
        op
          ..done = true
          ..doneStep = step
          ..error = error;
        if (error is Error) violate('${op.kind.name} threw a bug: $error');
        return null;
      },
    );
  }

  Future<void> flush() async {
    for (var turn = 0; turn < 4; turn++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
  }

  Future<void> advance(Duration by) async {
    advancing = true;
    await tester.pump(by);
    await flush();
    advancing = false;
  }

  T pick<T>(List<T> from) => from[rng.nextInt(from.length)];

  List<_Tab> get live => [
    for (final tab in tabs)
      if (!tab.retired) tab,
  ];

  List<FakeLinkClient> get open => [
    for (final client in clients)
      if (!client.isClosed) client,
  ];

  OpenReason _openReason(String kind) => switch (kind) {
    'UserAction' => UserAction(testIntent()),
    'AppResumed' => AppResumed(testSignal()),
    _ => NetworkChanged(testSignal()),
  };

  Future<void> establish() async {
    String kind = pick([
      'UserAction',
      'UserAction',
      'AppResumed',
      'NetworkChanged',
      'Reconnect',
    ]);
    if (kind == 'Reconnect' && reconnects.isEmpty) kind = 'UserAction';
    final OpenReason reason = kind == 'Reconnect'
        ? reconnects.removeAt(rng.nextInt(reconnects.length))
        : _openReason(kind);
    final failsStartup = rng.nextInt(10) == 0;
    final revives = rng.nextBool();
    final claims = rng.nextBool();
    log('establish $kind${failsStartup ? ' (startup fails)' : ''}');
    final op = _Op(_Kind.establish, step, reason: kind);
    unawaited(
      _track<ConnectionSupervisor>(
        op,
        () => connector.establish(
          address: _address,
          port: _port,
          user: _user,
          privateKey: _privateKey,
          verifier: HostKeyVerifier.pinnedOnly(_vm),
          reason: reason,
          startup: (supervisor) async {
            if (failsStartup) throw const SocketException('startup step');
            return supervisor;
          },
          failed: reconnects.add,
        ),
        (supervisor) {
          final tab = _Tab(++_tabs, supervisor, revives, step);
          if (revives) supervisor.reopenWhenHostDies();
          if (claims) {
            supervisor.claim();
            tab.claimed = true;
          }
          supervisor.controlLink.listen(
            null,
            onDone: () => tab.streamDone = true,
          );
          tabs.add(tab);
        },
      ),
    );
    await flush();
  }

  Future<void> openTab() async {
    if (tabs.isEmpty) return establish();
    final tab = rng.nextInt(8) == 0
        ? pick(tabs)
        : (live.isEmpty ? pick(tabs) : pick(live));
    final kind = pick(['UserAction', 'AppResumed', 'NetworkChanged']);
    log('open tab ${tab.id} for $kind');
    final reason = _openReason(kind) as ReopenReason;
    if (kind == 'AppResumed' && !tab.retired) tab.suspended = false;
    final wasRetired = tab.retired;
    final op = _Op(_Kind.open, step, tab: tab, reason: kind);
    unawaited(
      _track<HostChannels?>(op, () => tab.sup.open(reason), (channels) {
        if (channels == null) return;
        if (wasRetired) violate('a retired tab ${tab.id} opened channels');
        handed.add(_Handed(tab, channels, ++tick, mustBeNull: tab.retired));
      }),
    );
    await flush();
  }

  Future<void> dropTab() async {
    if (tabs.isEmpty) return;
    final tab = live.isEmpty || rng.nextInt(8) == 0 ? pick(tabs) : pick(live);
    final kind = pick([
      'UserClosed',
      'AppSuspended',
      'NetworkChanged',
      'ShellEnded',
    ]);
    log('drop tab ${tab.id} for $kind');
    final DropReason reason = switch (kind) {
      'UserClosed' => UserClosed(testIntent()),
      'AppSuspended' => AppSuspended(testSignal()),
      'NetworkChanged' => NetworkChanged(testSignal()),
      _ => tab.sup.terminalEnded(),
    };
    if (reason is ShellEnded) reconnects.add(reason.reconnect);
    tab.droppedTick = ++tick;
    switch (kind) {
      case 'UserClosed' || 'ShellEnded':
        _retire(tab);
      case 'AppSuspended':
        if (!tab.retired) {
          tab
            ..suspended = true
            ..blockedAt = step
            ..reviveArmed = false;
        }
    }
    unawaited(_quiet(tab.sup.drop(reason)));
    await flush();
  }

  void _retire(_Tab tab) {
    if (tab.retired) return;
    tab
      ..retired = true
      ..retiredAt = step
      ..blockedAt = step
      ..reviveArmed = false;
  }

  Future<void> _quiet(Future<void> future) => future.then(
    (_) {},
    onError: (Object error) {
      if (error is Error) violate('a drop threw a bug: $error');
    },
  );

  Future<void> foreignEnd() async {
    if (tabs.isEmpty) return;
    final tab = pick(tabs);
    final ShellEnded end;
    if (tabs.length > 1 && rng.nextBool()) {
      final other = pick([
        for (final candidate in tabs)
          if (!identical(candidate, tab)) candidate,
      ]);
      end = other.sup.terminalEnded();
    } else {
      end = ShellEnded.unbound();
    }
    log('drop tab ${tab.id} for another terminal\'s end');
    final before = dials.length;
    final closed = open.length;
    try {
      await tab.sup.drop(end);
      violate('tab ${tab.id} accepted an end it did not mint');
    } on ArgumentError {
      // ignored: the refusal is the asserted outcome, checked below
    }
    await flush();
    if (dials.length != before || open.length != closed) {
      violate('a refused end changed the connections');
    }
  }

  Future<void> hostDies() async {
    final candidates = open;
    if (candidates.isEmpty) return;
    final client = pick(candidates);
    log('host of client ${clients.indexOf(client)} dies');
    await client.close();
    await flush();
  }

  void arm() {
    final outcome = pick([_Outcome.fail, _Outcome.settle, _Outcome.slow]);
    log('next dial ${outcome.name}');
    queue.add(outcome);
  }

  Future<void> settle() async {
    if (settles.isEmpty) return;
    log('a settle lifts');
    settles.removeAt(0).complete();
    await flush();
  }

  Future<void> land() async {
    if (gates.isEmpty) return;
    log('a slow dial lands');
    gates.removeAt(0).complete();
    await flush();
  }

  Future<void> checkAnswered() async {
    if (tabs.isEmpty) return;
    final tab = pick(tabs);
    log('check tab ${tab.id}, answered');
    final before = dials.length;
    final closed = open.length;
    unawaited(_quiet(tab.sup.check()));
    await flush();
    if (dials.length != before) violate('an answered check dialled');
    if (open.length != closed) violate('an answered check closed a connection');
  }

  Future<void> checkUnanswered() async {
    final holders = [
      for (final tab in live)
        if (tab.held case final client? when !client.isClosed) (tab, client),
    ];
    if (holders.isEmpty) return;
    final (tab, client) = pick(holders);
    log('check tab ${tab.id}, unanswered');
    final pong = client.pong = Completer<void>();
    final before = dials.length;
    unawaited(_quiet(tab.sup.check()));
    await advance(links.answer);
    if (!client.isClosed) violate('a check left a link that missed it');
    if (dials.skip(before).any((dial) => dial.causes.isEmpty)) {
      violate('a missed check dialled');
    }
    client.pong = null;
    pong.complete();
    await flush();
  }

  Future<void> keepaliveUnanswered() async {
    final candidates = open;
    if (candidates.isEmpty) return;
    final client = pick(candidates);
    log('client ${clients.indexOf(client)} stops answering keepalives');
    final pong = client.pong = Completer<void>();
    for (var round = 0; round < links.keepAliveMisses + 1; round++) {
      await advance(links.keepAlive);
    }
    if (!client.isClosed) violate('a link silent past its keepalive lived on');
    client.pong = null;
    pong.complete();
    await flush();
  }

  Future<void> execHanded() async {
    final choices = <HostChannels>[
      for (final entry in handed) entry.channels,
      for (final tab in tabs) tab.sup.channels,
    ];
    if (choices.isEmpty) return;
    log('exec through handed-out channels');
    final op = _Op(_Kind.exec, step);
    unawaited(
      _track<ExecResult?>(
        op,
        () => pick(choices).exec('work', timeout: const Duration(seconds: 5)),
      ),
    );
    await flush();
  }

  Future<void> execTimeout() async {
    final holders = [
      for (final tab in live)
        if (tab.held case final client? when !client.isClosed) (tab, client),
    ];
    if (holders.isEmpty) return;
    final (tab, client) = pick(holders);
    log('exec on tab ${tab.id} times out');
    final gate = client.execGate = Completer<void>();
    const within = Duration(milliseconds: 200);
    final op = _Op(_Kind.exec, step);
    unawaited(
      _track<ExecResult?>(op, () => tab.sup.exec('stuck', timeout: within)),
    );
    await advance(within);
    if (!op.done || op.error is! TimeoutException) {
      violate('an exec past its deadline did not time out: ${op.error}');
    }
    if (client.isClosed) violate('an exec timeout closed its connection');
    client.execGate = null;
    gate.complete();
    await flush();
  }

  Future<void> overflow() async {
    final holders = [
      for (final tab in live)
        if (tab.held case final client? when !client.isClosed) (tab, client),
    ];
    if (holders.isEmpty) return;
    final (tab, client) = pick(holders);
    log('host limit refuses sessions on tab ${tab.id}');
    client.execError = SSHChannelOpenError(1, 'prohibited');
    final before = dials.length;
    for (var i = 0; i < 2; i++) {
      final op = _Op(_Kind.exec, step);
      unawaited(
        _track<ExecResult?>(
          op,
          () => tab.sup.exec('spill', timeout: const Duration(seconds: 5)),
        ),
      );
    }
    await flush();
    if (dials.length - before > 1) violate('two overflows dialled at once');
    client.execError = null;
    await flush();
  }

  Future<void> advanceTime() async {
    final by = pick(const [
      Duration(milliseconds: 100),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
      Duration(minutes: 3),
    ]);
    log('time +${by.inMilliseconds}ms');
    await advance(by);
  }

  Future<void> sleepOrWake() async {
    if (asleep) {
      log('wake');
      links.wake();
      asleep = false;
    } else {
      log('sleep');
      links.sleep();
      asleep = true;
    }
    await flush();
  }

  Future<void> leaseOrRelease() async {
    final held = [
      for (final entry in mine)
        if (!entry.released) entry,
    ];
    if (held.isNotEmpty && rng.nextBool()) {
      final entry = pick(held);
      log('release my ${entry.lease.use.label} lease');
      entry.lease.release();
      entry.released = true;
      await flush();
      return;
    }
    final use = pick(const [
      HostUse.herdrPoll,
      HostUse.send,
      HostUse.alertAction,
      HostUse.workspace,
      HostUse.vnc,
    ]);
    if (use.lane == HostLane.screen) screenUsed = true;
    log('lease for ${use.label}');
    final wasAsleep = asleep;
    final op = _Op(_Kind.lease, step, use: use);
    unawaited(
      _track<HostLease>(
        op,
        () => links.lease(
          address: _address,
          port: _port,
          user: _user,
          privateKey: _privateKey,
          verifier: HostKeyVerifier.pinnedOnly(_vm),
          use: use,
        ),
        (lease) {
          if ((wasAsleep || asleep) && !use.wakes) {
            violate('a ${use.label} lease was granted asleep');
          }
          mine.add(_Mine(lease));
        },
      ),
    );
    await flush();
  }

  Future<void> discard() async {
    if (tabs.isEmpty) return;
    final tab = pick(tabs);
    log('discard tab ${tab.id}');
    final claimed = tab.sup.claimed;
    if (claimed != tab.claimed) violate('tab ${tab.id} forgot its claim');
    if (!claimed) {
      tab.droppedTick = ++tick;
      _retire(tab);
    }
    unawaited(
      tab.sup.discard().then((dropped) {
        if (dropped == claimed) {
          violate('discard answered $dropped claimed $claimed');
        }
      }),
    );
    await flush();
  }

  Future<void> claimTab() async {
    if (tabs.isEmpty) return;
    final tab = pick(tabs);
    log('claim tab ${tab.id}');
    tab.sup.claim();
    tab.claimed = true;
  }

  Future<void> observe() async {
    final heldBefore = {for (final tab in tabs) tab: tab.held};
    final closedBefore = {
      for (final client in clients) client: client.isClosed,
    };
    final probes = <(String, Future<ExecResult?>)>[];
    final answers = <String, ExecResult?>{};
    final failures = <String, Object>{};
    String probe(HostChannels channels) {
      final command = 'probe ${++_probes}';
      final future = channels.exec(
        command,
        timeout: const Duration(seconds: 1),
      );
      probes.add((command, future));
      unawaited(
        future.then(
          (result) => answers[command] = result,
          onError: (Object error) => failures[command] = error,
        ),
      );
      return command;
    }

    final tabProbes = {for (final tab in tabs) tab: probe(tab.sup)};
    final handedProbes = {
      for (final entry in handed) entry: probe(entry.channels),
    };
    await flush();
    for (final (command, _) in probes) {
      if (failures[command] case final error?) {
        violate('a probe failed: $error');
      } else if (!answers.containsKey(command)) {
        violate('a probe never answered');
      }
    }

    FakeLinkClient? ranOn(String command) {
      if (answers[command] == null) return null;
      for (final client in clients) {
        if (client.commands.contains(command)) return client;
      }
      violate('a probe ran on no dialled client');
      return null;
    }

    final closedNow = [
      for (final client in clients)
        if (client.isClosed && closedBefore[client] == false) client,
    ];
    for (final tab in tabs) {
      final client = ranOn(tabProbes[tab]!);
      if (tab.retired && client != null) {
        violate('retired tab ${tab.id} holds a host');
      }
      if (client != null && client.isClosed) {
        violate('tab ${tab.id} holds a closed host');
      }
      if (client != null && !identical(client, heldBefore[tab])) {
        final reason =
            tab.createdStep == step ||
            tab.reviveArmed ||
            (tab.revives &&
                !tab.suspended &&
                (heldBefore[tab]?.isClosed ?? false)) ||
            ops.any(
              (op) =>
                  identical(op.tab, tab) &&
                  op.kind == _Kind.open &&
                  (!op.done || op.doneStep == step) &&
                  _opens(op) &&
                  (op.issued > tab.blockedAt || op.reason == 'UserAction'),
            );
        if (!reason) {
          violate('tab ${tab.id} came to hold a host with no reason');
        }
      }
      final before = heldBefore[tab];
      final pending = ops.any(
        (op) => identical(op.tab, tab) && (!op.done || op.doneStep == step),
      );
      if (tab.revives &&
          !tab.retired &&
          !tab.suspended &&
          ((before != null && before.isClosed) ||
              (pending && closedNow.isNotEmpty))) {
        tab.reviveArmed = true;
      }
      tab.held = client;
      if (tab.retired && !tab.streamDone) {
        violate('retired tab ${tab.id} still streams its control link');
      }
    }

    for (final entry in handed) {
      final client = ranOn(handedProbes[entry]!);
      final dropped = entry.tab.droppedTick > entry.tick;
      if (client == null) {
        final known = entry.client;
        if (!entry.nulled && known != null && !known.isClosed && !dropped) {
          violate('a live lease of tab ${entry.tab.id} answered null');
        }
        entry.nulled = true;
        continue;
      }
      if (entry.nulled) violate('a lease that answered null answered again');
      if (entry.mustBeNull) violate('a lease handed out retired answered');
      if (dropped) {
        violate('a lease of tab ${entry.tab.id} answered after a drop');
      }
      if (client.isClosed) violate('a lease answered on a closed host');
      final known = entry.client;
      if (known != null && !identical(known, client)) {
        violate('a lease moved to another host');
      }
      entry.client = client;
    }

    final live = open.length;
    if (links.open != live) {
      violate('HostLinks counts ${links.open} links over $live open sockets');
    }
    final execs = ops.any((op) => op.kind == _Kind.exec && !op.done);
    final cap = 1 + (screenUsed ? 1 : 0) + (execs ? 1 : 0);
    if (live > cap) violate('$live sockets open for one identity, cap $cap');

    if (asleep) {
      for (final entry in mine) {
        if (!entry.released && !entry.lease.use.wakes && !entry.lease.closed) {
          violate('a ${entry.lease.use.label} lease is held asleep');
        }
      }
      final holders =
          tabs.any((tab) => tab.held != null) ||
          mine.any(
            (entry) =>
                !entry.released && entry.lease.use.wakes && !entry.lease.closed,
          );
      if (!holders && links.open != 0) {
        violate('asleep with nothing holding, ${links.open} links stay open');
      }
    }

    ops.removeWhere(
      (op) => op.done && op.doneStep != null && op.doneStep! < step,
    );
  }

  void expectClean() {
    expect(
      violations,
      isEmpty,
      reason: 'events leading here:\n${trace.join('\n')}',
    );
  }

  Future<void> run(int steps) async {
    final events = <(int, Future<void> Function())>[
      (6, establish),
      (10, openTab),
      (8, dropTab),
      (1, foreignEnd),
      (4, hostDies),
      (5, () async => arm()),
      (3, settle),
      (3, land),
      (3, checkAnswered),
      (2, checkUnanswered),
      (1, keepaliveUnanswered),
      (4, execHanded),
      (2, execTimeout),
      (2, overflow),
      (10, advanceTime),
      (2, sleepOrWake),
      (4, leaseOrRelease),
      (1, discard),
      (1, claimTab),
    ];
    final total = events.fold(0, (sum, event) => sum + event.$1);
    for (step = 1; step <= steps; step++) {
      var roll = rng.nextInt(total);
      for (final (weight, event) in events) {
        if (roll < weight) {
          await event();
          break;
        }
        roll -= weight;
      }
      await observe();
      expectClean();
    }
    await drain();
  }

  Future<void> drain() async {
    step++;
    log('drain');
    queue.clear();
    if (asleep && rng.nextBool()) {
      links.wake();
      asleep = false;
    }
    for (var round = 0; round < 20; round++) {
      for (final gate in gates) {
        gate.complete();
      }
      gates.clear();
      for (final settle in settles) {
        settle.complete();
      }
      settles.clear();
      for (final tab in live) {
        tab.droppedTick = ++tick;
        _retire(tab);
        unawaited(_quiet(tab.sup.drop(UserClosed(testIntent()))));
      }
      for (final entry in mine) {
        if (entry.released) continue;
        entry.lease.release();
        entry.released = true;
      }
      await advance(const Duration(minutes: 3));
      if (ops.every((op) => op.done) &&
          live.isEmpty &&
          mine.every((entry) => entry.released) &&
          gates.isEmpty &&
          settles.isEmpty) {
        break;
      }
    }
    await advance(links.linger + const Duration(seconds: 1));
    await observe();
    for (final op in ops) {
      if (!op.done) {
        violate(
          'a ${op.kind.name} ${op.reason ?? op.use?.label ?? ''} from step '
          '${op.issued} on tab ${op.tab?.id} never finished',
        );
      }
    }
    if (open.isNotEmpty) {
      violate('${open.length} sockets stayed open after every tab retired');
    }
    if (links.open != 0) violate('HostLinks kept ${links.open} links');
    expectClean();
    links.close();
  }
}

void main() {
  for (final seed in _seeds) {
    testWidgets(
      'seed $seed holds the connection policy through random events',
      (tester) async {
        final printer = debugPrint;
        debugPrint = (message, {wrapWidth}) {};
        try {
          await _Model(tester, seed).run(_steps);
        } finally {
          debugPrint = printer;
        }
      },
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade_luau/data_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:path_provider/path_provider.dart';

import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/shell/daemon_link.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/ssh/ssh_settle.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/shell/path_scan.dart';
import 'package:upgrade/platform/plugins/serial.dart';

typedef PluginHostConfirm = Future<bool> Function(
  Host host,
  String service,
  Set<String> operations,
);
typedef PluginHostTransport = Future<Map<String, Object?>> Function(
  Host host,
  String scope,
  String operation,
  Map<String, Object?> args,
);
typedef PluginEngineCall = Future<Map<String, Object?>> Function(
  Host host,
  String service,
  String operation,
  Map<String, Object?> args,
);

/// One per tap: an effect chain that started from an `action` event carries it, and an
/// operation that only a person may cause takes it, once.
class PluginHostGesture {
  PluginHostGesture(this._open);
  final void Function(Host host, AgentSnapshot agent) _open;
  var _spent = false;

  bool take() {
    if (_spent) return false;
    _spent = true;
    return true;
  }

  void open(Host host, AgentSnapshot agent) => _open(host, agent);
}

class PluginHostService {
  const PluginHostService({
    required this.operations,
    required this.invoke,
    this.deactivate,
    this.reconcile,
    this.changes,
    this.hold,
  });
  final Set<String> operations;
  final Future<Object?> Function(
    InstalledPlugin plugin,
    String operation,
    Map<String, Object?> args,
    PluginHostConfirm confirm,
    void Function() check,
    PluginHostGesture? gesture,
  )
  invoke;
  final Future<void> Function(InstalledPlugin plugin)? deactivate;

  final Future<void> Function(Set<String> activeOwners)? reconcile;

  final ProviderListenable<Object?>? changes;

  final VoidCallback Function()? hold;
}

class PluginHostUsage {
  int calls = 0;
  int failed = 0;
  int elapsedMicros = 0;
  int sentBytes = 0;
  int receivedBytes = 0;
}

class PluginHostRegistry {
  PluginHostRegistry(this.services, {this.retryPending});
  final Map<String, PluginHostService> services;
  final Future<void> Function()? retryPending;

  Future<void> reconcile(Set<String> activeOwners) async {
    await Future.wait([
      for (final service in services.values)
        ?service.reconcile?.call(activeOwners),
    ]);
  }

  final _usage = <String, Map<String, PluginHostUsage>>{};
  Map<String, PluginHostUsage> usage(InstalledPlugin plugin) =>
      Map.unmodifiable(_usage[pluginHostOwner(plugin)] ?? {});
  Future<Object?> invoke(
    InstalledPlugin plugin,
    Map<String, Object?> effect,
    PluginHostConfirm confirm,
    void Function() check, {
    PluginHostGesture? gesture,
  }) async {
    final alias = effect['capability'];
    final capability = plugin.manifest.hostCapabilities[alias];
    final operation = effect['operation'];
    final key = capability?.operations.contains(operation) == true
        ? '$alias.$operation'
        : 'rejected';
    final usage = (_usage[pluginHostOwner(plugin)] ??= {}).putIfAbsent(
      key,
      PluginHostUsage.new,
    );
    final clock = Stopwatch()..start();
    usage.calls++;
    try {
      usage.sentBytes += utf8.encode(jsonEncode(effect['args'])).length;
      final result = await _invoke(plugin, effect, confirm, check, gesture);
      usage.receivedBytes += utf8.encode(jsonEncode(result)).length;
      return result;
    } catch (_) {
      usage.failed++;
      rethrow;
    } finally {
      usage.elapsedMicros += clock.elapsedMicroseconds;
    }
  }

  Future<Object?> _invoke(
    InstalledPlugin plugin,
    Map<String, Object?> effect,
    PluginHostConfirm confirm,
    void Function() check,
    PluginHostGesture? gesture,
  ) async {
    final alias = effect['capability'];
    final operation = effect['operation'];
    final capability = plugin.manifest.hostCapabilities[alias];
    final service = capability == null ? null : services[capability.service];
    if (!plugin.enabled ||
        operation is! String ||
        capability == null ||
        service == null ||
        !capability.operations.contains(operation) ||
        !service.operations.contains(operation) ||
        !plugin.grants.contains(capability.permission(operation))) {
      throw const PluginException(
        'Host operation is not declared, supported and granted',
      );
    }
    final args = effect['args'];
    if (args is! Map<String, Object?>) {
      throw const PluginException('Invalid host arguments');
    }
    check();
    final result = await service.invoke(
      plugin,
      operation,
      args,
      confirm,
      check,
      gesture,
    );
    check();
    return result;
  }

  Future<void> deactivate(InstalledPlugin plugin, {String? only}) async {
    await Future.wait([
      for (final service
          in plugin.manifest.hostCapabilities.values
              .map((c) => c.service)
              .where((service) => only == null || service == only)
              .toSet())
        ?services[service]?.deactivate?.call(plugin),
    ]);
  }
}

String pluginAgentId(Host host, AgentSnapshot agent) =>
    '${host.id}/${agent.source.name}/${agent.session}/${agent.paneId}';

Map<String, Object?> pluginAgentList(AgentPanelState? feed, DateTime now) {
  if (feed == null) {
    return {'ready': false, 'hosts': <Object?>[], 'items': <Object?>[]};
  }
  final hosts = <String, Map<String, Object?>>{};
  for (final outcome in feed.outcomes) {
    final entry = hosts.putIfAbsent(
      outcome.host.id,
      () => {'id': outcome.host.id, 'name': outcome.host.name, 'ok': false},
    );
    if (outcome.ok) entry['ok'] = true;
    final at = outcome.lastGoodAt;
    final kept = entry['read_at'] as String?;
    if (at != null && (kept == null || DateTime.parse(kept).isBefore(at))) {
      entry['read_at'] = at.toUtc().toIso8601String();
      entry['read_ago'] = now.difference(at).inSeconds.clamp(0, 1 << 31);
    }
  }
  for (final failure in feed.failures) {
    hosts[failure.host.id]?['reason'] ??= failure.namedReason;
  }
  return {
    'ready': true,
    'hosts': hosts.values.toList(),
    'items': [
      for (final outcome in feed.outcomes)
        for (final agent in outcome.agents)
          {
            'id': pluginAgentId(outcome.host, agent),
            'host': outcome.host.id,
            'host_name': outcome.host.name,
            'agent': agent.agent,
            'state': agent.state.word,
            'title': agent.terminalTitleStripped,
            'workspace': agent.workspaceLabel ?? '',
            'directory': agent.cwd,
            'question': agent.question ?? '',
            'message': agent.message ?? '',
            'source': agent.source.name,
            'seq': agent.stateChangeSeq,
            if (agent.approval case final approval?)
              'approval': {
                'id': approval.id,
                'tool': approval.tool,
                'line': approval.line,
              },
          },
    ],
  };
}

String pluginHostOwner(InstalledPlugin plugin) => sha256
    .convert(utf8.encode(DataOwner(plugin.id, plugin.package.origin).identity))
    .toString();

/// Luau has one number type, so every whole number a plugin writes arrives here as
/// a double and would go on the wire spelled `0.0`. The engine's fields are typed,
/// and it is right to refuse a fraction where it asked for a count, so the whole
/// ones are put back the way the plugin meant them rather than the ABI loosened.
@visibleForTesting
Object? wholeNumbers(Object? value) => switch (value) {
  final double number
      when number.isFinite && number == number.roundToDouble() =>
    number.toInt(),
  final Map<String, Object?> map => {
    for (final entry in map.entries) entry.key: wholeNumbers(entry.value),
  },
  final List<Object?> list => [for (final item in list) wholeNumbers(item)],
  _ => value,
};

final schedulerTransportProvider = Provider<PluginHostTransport>((ref) {
  final engine = ref.watch(pluginEngineProvider);
  return (host, scope, operation, args) =>
      engine(host, 'schedule/1', operation, {...args, 'scope': scope});
});

final pluginEngineProvider = Provider<PluginEngineCall>((ref) {
  final keys = ref.watch(privateKeyStoreProvider);
  final links = ref.read(hostLinksProvider);
  return (host, service, operation, args) async {
    if (host.hostKey == null) {
      throw const PluginException(
        'Verify the host key in MACHINES before connecting',
      );
    }
    final privateKey = await keys.read(host.keyId);
    if (privateKey == null) {
      throw const PluginException('Host private key is unavailable');
    }
    Future<Map<String, Object?>> overSsh(
      String service,
      String operation,
      Map<String, Object?> args,
    ) async {
      final HostLease lease;
      try {
        lease = await links.lease(
          address: host.address,
          port: host.port,
          user: host.user,
          privateKey: privateKey,
          verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
          use: HostUse.pluginScheduler,
        );
      } on HerdrFailure catch (error) {
        throw PluginException(error.reason(host.name, address: host.address));
      }
      try {
        return await engineOver(
          (command) => lease.execute(command),
          service,
          host.user,
          operation,
          args,
        );
      } on SSHChannelOpenError {
        throw const PluginException('Host busy');
      } finally {
        lease.release();
      }
    }

    final String? answer;
    try {
      answer = await EngineDaemons.shared.call(
        address: host.address,
        user: host.user,
        body: _engineBody(service, host.user, operation, args),
        timeout: _engineDeadline,
        start: () => overSsh('daemon/1', 'start', const {}),
      );
    } on DaemonFailed catch (error) {
      throw PluginException('Host engine did not answer. ${error.message}');
    }
    if (answer == null) return overSsh(service, operation, args);
    if (answer.length > _engineAnswerLimit) {
      throw const PluginException('Host response exceeds its limit');
    }
    final Object? response;
    try {
      response = jsonDecode(answer);
    } on FormatException {
      throw const PluginException('Host engine did not answer.');
    }
    return _engineResult(response, service);
  };
});

const _engineDeadline = Duration(seconds: 45);
const _engineAnswerLimit = 512 * 1024;

String _engineBody(
  String service,
  String owner,
  String operation,
  Map<String, Object?> args,
) => jsonEncode(
  engineRequest(
    service,
    operation,
    wholeNumbers(args) as Map<String, Object?>,
    owner: owner,
  ),
);

@visibleForTesting
Future<Map<String, Object?>> scheduleOver(
  Future<SSHSession> Function(String command) execute,
  String owner,
  String scope,
  String operation,
  Map<String, Object?> args,
) => engineOver(execute, 'schedule/1', owner, operation, {
  ...args,
  'scope': scope,
});

Future<Map<String, Object?>> engineOver(
  Future<SSHSession> Function(String command) execute,
  String service,
  String owner,
  String operation,
  Map<String, Object?> args,
) async {
  final session = await openWithin(
    execute('upgraded'),
    const Duration(seconds: 10),
    endExec,
  );
  try {
    final output = BytesBuilder(copy: false);
    final errors = BytesBuilder(copy: false);
    void append(BytesBuilder buffer, Uint8List bytes, int limit) {
      if (buffer.length + bytes.length > limit) {
        endExec(session);
        throw const PluginException('Host response exceeds its limit');
      }
      buffer.add(bytes);
    }

    final exchange = Future.wait<void>([
      session.stdout.forEach(
        (bytes) => append(output, bytes, _engineAnswerLimit),
      ),
      session.stderr.forEach((bytes) => append(errors, bytes, 16 * 1024)),
    ]);
    session.stdin.add(
      Uint8List.fromList(
        utf8.encode(_engineBody(service, owner, operation, args)),
      ),
    );
    await session.stdin.close();
    await exchange.timeout(_engineDeadline);
    await session.done.timeout(const Duration(seconds: 5));
    final raw = utf8.decode(output.takeBytes());
    final Object? response;
    try {
      response = jsonDecode(raw);
    } on FormatException {
      final complaint = utf8
          .decode(errors.takeBytes(), allowMalformed: true)
          .trim();
      // A machine with no engine answers over the shell instead: 127 and a line of its own.
      if (session.exitCode == 127 || complaint.endsWith('not found')) {
        throw const PluginException('This host has no upgraded installed');
      }
      throw PluginException('Host engine did not answer. $complaint');
    }
    return _engineResult(response, service);
  } finally {
    endExec(session);
  }
}

Map<String, Object?> _engineResult(Object? response, String service) {
  if (response is! Map<String, Object?>) {
    throw const PluginException('Invalid engine response');
  }
  if (response['ok'] != true) {
    final error = response['error'];
    final failure = error is Map<String, Object?>
        ? error
        : const <String, Object?>{};
    final message = failure['message'] is String
        ? failure['message']! as String
        : 'Host engine failed';
    throw PluginException(
      failure['kind'] == 'unsupported'
          ? "This host's engine does not carry $service. $message"
          : message,
    );
  }
  final result = response['result'];
  if (result is! Map<String, Object?>) {
    throw const PluginException('Invalid engine result');
  }
  return result;
}

class SchedulerBinding {
  const SchedulerBinding({this.configured = false, this.pending = false});
  final bool configured;
  final bool pending;
  Map<String, Object?> toJson() => {
    'configured': configured,
    'pending': pending,
  };
}

class SchedulerBindings {
  SchedulerBindings(this.file);
  final Future<File> Function() file;
  final _serial = Serial();
  Future<Map<String, Map<String, SchedulerBinding>>> read() async {
    final target = await file();
    if (!await target.exists()) return {};
    if (await target.length() > 512 * 1024) {
      throw const PluginException('Host binding file exceeds its limit');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await target.readAsString());
    } on FormatException {
      throw const PluginException('Host bindings are corrupt; file retained');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != 1 ||
        decoded['owners'] is! Map<String, Object?>) {
      throw const PluginException('Unsupported host bindings; file retained');
    }
    final owners = decoded['owners']! as Map<String, Object?>;
    final result = <String, Map<String, SchedulerBinding>>{};
    for (final owner in owners.entries) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(owner.key) ||
          owner.value is! Map<String, Object?>) {
        throw const PluginException('Invalid host binding owner');
      }
      final hosts = owner.value! as Map<String, Object?>;
      if (hosts.values.any(
        (value) =>
            value is! Map<String, Object?> ||
            value['configured'] is! bool ||
            value['pending'] is! bool,
      )) {
        throw const PluginException('Invalid pending pause state');
      }
      result[owner.key] = {
        for (final host in hosts.entries)
          host.key: SchedulerBinding(
            configured:
                (host.value! as Map<String, Object?>)['configured']! as bool,
            pending: (host.value! as Map<String, Object?>)['pending']! as bool,
          ),
      };
    }
    return result;
  }

  Future<void> set(String owner, String host, SchedulerBinding binding) {
    return _serial.run(() async {
      final state = await read();
      (state[owner] ??= {})[host] = binding;
      await replaceFile(
        await file(),
        jsonEncode({'version': 1, 'owners': state}),
      );
    });
  }
}

final schedulerBindingsProvider = Provider(
  (ref) => SchedulerBindings(() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/plugins/host-bindings.json');
  }),
);

final pluginHostPendingProvider = FutureProvider.autoDispose
    .family<int, String>(
      (ref, owner) async =>
          (await ref.watch(schedulerBindingsProvider).read())[owner]?.values
              .where((binding) => binding.pending)
              .length ??
          0,
    );

final pendingHostPausesProvider = FutureProvider.autoDispose<int>(
  (ref) async => (await ref.watch(schedulerBindingsProvider).read()).values
      .expand((hosts) => hosts.values)
      .where((binding) => binding.pending)
      .length,
);

Future<Host> _pick(HostRepository hosts, Object? id) async {
  final host = (await hosts.all()).where((host) => host.id == id).firstOrNull;
  if (host == null) throw const PluginException('Choose an existing host');
  return host;
}

final _runNonce = RegExp(r'^[A-Za-z0-9]{1,32}$');
const _runLive = 4;

Iterable<Map<String, Object?>> _liveJobs(Map<String, Object?> listed) =>
    (listed['jobs'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .where(
          (job) => job['state'] == 'starting' || job['state'] == 'running',
        );

/// The engine checks no owner on a job id, so every id is held to the plugin's tag.
class PluginRunHosts {
  PluginRunHosts(this.file);
  final Future<File> Function() file;
  final _serial = Serial();

  Future<Map<String, Set<String>>> _read() async {
    final target = await file();
    if (!await target.exists()) return {};
    if (await target.length() > 256 * 1024) {
      return _setAside(target);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await target.readAsString());
    } on FormatException {
      return _setAside(target);
    } on FileSystemException {
      return _setAside(target);
    }
    final owners = decoded is Map<String, Object?> && decoded['version'] == 1
        ? decoded['owners']
        : null;
    if (owners is! Map<String, Object?> ||
        owners.values.any(
          (hosts) =>
              hosts is! List<Object?> || hosts.any((id) => id is! String),
        )) {
      return _setAside(target);
    }
    return {
      for (final MapEntry(:key, :value) in owners.entries)
        key: (value! as List<Object?>).cast<String>().toSet(),
    };
  }

  Future<Never> _setAside(File target) async {
    try {
      await target.rename('${target.path}.corrupt');
    } on FileSystemException {
      // ignored: a racing read already moved the file aside.
    }
    throw PluginException(
      'Run hosts were unreadable; moved to ${target.path}.corrupt',
    );
  }

  Future<Set<String>> read(String owner) =>
      _serial.run(() async => (await _read())[owner] ?? const <String>{});

  Future<Set<String>> owners() =>
      _serial.run(() async => (await _read()).keys.toSet());

  Future<void> _change(void Function(Map<String, Set<String>> state) change) {
    return _serial.run(() async {
      final state = await _read();
      change(state);
      await replaceFile(
        await file(),
        jsonEncode({
          'version': 1,
          'owners': {
            for (final MapEntry(:key, :value) in state.entries)
              if (value.isNotEmpty) key: value.toList(),
          },
        }),
      );
    });
  }

  Future<void> add(String owner, String host) =>
      _change((state) => (state[owner] ??= {}).add(host));

  Future<void> remove(String owner, Iterable<String> hosts) =>
      _change((state) => state[owner]?.removeAll(hosts));
}

final pluginRunHostsProvider = Provider(
  (ref) => PluginRunHosts(() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/plugins/run-hosts.json');
  }),
);

@visibleForTesting
PluginHostService pluginRunService(
  HostRepository hosts,
  PluginEngineCall engine,
  PluginRunHosts used, {
  Random? random,
}) {
  final nonces = random ?? Random.secure();
  final allowed = <String>{};
  final refused = <String>{};
  final queues = <String, Serial>{};
  Future<T> serialized<T>(String owner, Future<T> Function() work) =>
      queues.putIfAbsent(owner, Serial.new).run(work);

  String tagOf(String owner) => 'p${owner.substring(0, 16)}';

  String jobOf(String tag, Object? id) {
    if (id is! String || !id.startsWith('$tag-')) {
      throw const PluginException('Not a job this plugin started');
    }
    return id;
  }

  Map<String, Object?> clamped(Map<String, Object?> args) {
    int? lines(Object? value) => value is num && value.isFinite
        ? value.toInt().clamp(1, 500)
        : value == null
        ? null
        : throw const PluginException('head and tail are line counts');
    final grep = args['grep'];
    if (grep != null && (grep is! String || grep.length > 128)) {
      throw const PluginException('grep is a string of at most 128 characters');
    }
    final stream = args['stream'];
    if (stream != null && stream != 'stdout' && stream != 'stderr') {
      throw const PluginException('stream is stdout or stderr');
    }
    final limit = args['limit'];
    return {
      'stream': ?stream,
      'grep': ?grep,
      if (args['ignore_case'] == true) 'ignore_case': true,
      if (args['invert'] == true) 'invert': true,
      'head': ?lines(args['head']),
      'tail': ?lines(args['tail']),
      'limit': limit is num && limit.isFinite
          ? limit.toInt().clamp(1, 64 * 1024)
          : 32 * 1024,
    };
  }

  Future<void> cleanup(String owner) async {
    final tag = tagOf(owner);
    allowed.removeWhere((key) => key.startsWith('$owner/'));
    refused.removeWhere((key) => key.startsWith('$owner/'));
    Set<String> ran;
    try {
      ran = await used.read(owner);
    } on PluginException {
      ran = {for (final host in await hosts.all()) host.id};
    }
    final reached = await Future.wait([
      for (final id in ran)
        () async {
          final host = (await hosts.all())
              .where((host) => host.id == id)
              .firstOrNull;
          if (host == null) return id;
          try {
            await serialized('$owner/$id', () async {
              final listed = await engine(host, 'run/1', 'list', {
                'tag': tag,
                'live': true,
              });
              for (final job in _liveJobs(listed)) {
                await engine(host, 'run/1', 'cancel', {'id': job['id']});
              }
            });
            return id;
          } on Object {
            // ignored: an unreachable host stays in the file until the next disable or start.
            return null;
          }
        }(),
    ]);
    await used.remove(owner, reached.nonNulls);
  }

  return PluginHostService(
    operations: const {'submit', 'list', 'status', 'output', 'cancel'},
    deactivate: (plugin) => cleanup(pluginHostOwner(plugin)),
    reconcile: (activeOwners) async {
      for (final owner in await used.owners()) {
        if (!activeOwners.contains(owner)) await cleanup(owner);
      }
    },
    invoke: (plugin, operation, args, confirm, check, gesture) async {
      final host = await _pick(hosts, args['host']);
      final owner = pluginHostOwner(plugin);
      final tag = tagOf(owner);
      final capabilities = plugin.manifest.hostCapabilities.values.where(
        (capability) =>
            capability.service == 'run' &&
            plugin.grants.contains(capability.permission('submit')),
      );
      final key = '$owner/${plugin.package.digest}/${host.id}';
      var tapped = false;
      if (!allowed.contains(key)) {
        if (refused.contains(key)) {
          if (operation != 'submit' || gesture == null || !gesture.take()) {
            throw const PluginException('Host access was not granted');
          }
          tapped = true;
        }
        final shown = {
          for (final capability in capabilities)
            for (final command in capability.commands.values) command.shown,
        };
        if (!await confirm(host, 'run', shown)) {
          refused.add(key);
          throw const PluginException('Host access was not granted');
        }
        check();
        refused.remove(key);
        allowed.add(key);
      }
      Future<Map<String, Object?>> call(String op, Map<String, Object?> body) =>
          engine(host, 'run/1', op, body);
      switch (operation) {
        case 'list':
          return call('list', {'tag': tag});
        case 'status':
          return call('status', {'id': jobOf(tag, args['id'])});
        case 'cancel':
          return call('cancel', {'id': jobOf(tag, args['id'])});
        case 'output':
          return call('output', {
            'id': jobOf(tag, args['id']),
            ...clamped(args),
          });
      }
      final name = args['command'];
      final command = name is String
          ? capabilities
                .map((capability) => capability.commands[name])
                .nonNulls
                .firstOrNull
          : null;
      if (command == null) {
        throw const PluginException('Not a command this plugin declares');
      }
      final given = args['params'] ?? const <String, Object?>{};
      if (given is! Map<String, Object?> ||
          !setEquals(given.keys.toSet(), command.parameters)) {
        throw PluginException(
          'Pass exactly the parameters ${command.parameters.join(', ')}',
        );
      }
      final values = <String, String>{};
      for (final MapEntry(:key, :value) in given.entries) {
        if (value is! String || !pluginRunValue.hasMatch(value)) {
          throw PluginException(
            '$key is one word of letters, digits and _.,/- that does not start with -',
          );
        }
        if (command.choices[key] case final choices?
            when !choices.contains(value)) {
          throw PluginException('$key is one of ${choices.join(', ')}');
        }
        values[key] = value;
      }
      final nonce = args['id'];
      if (nonce != null && (nonce is! String || !_runNonce.hasMatch(nonce))) {
        throw const PluginException('A job id is 1 to 32 letters and digits');
      }
      if (!tapped && (gesture == null || !gesture.take())) {
        throw const PluginException('Commands run only from a tap');
      }
      return serialized('$owner/${host.id}', () async {
        final listed = await call('list', {'tag': tag, 'live': true});
        check();
        if (_liveJobs(listed).length >= _runLive) {
          throw const PluginException(
            '$_runLive commands are already running on this host',
          );
        }
        await used.add(owner, host.id);
        check();
        return call('submit', {
          'id':
              '$tag-${nonce ?? [for (var i = 0; i < 8; i++) nonces.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}',
          'argv': command.resolve(values),
          'cwd': ?command.cwd,
          'timeout_ms': command.timeout.inMilliseconds,
          'tag': tag,
        });
      });
    },
  );
}

class PluginScheduler {
  PluginScheduler(this.hosts, this.transport, this.bindings, this.changed);
  final HostRepository hosts;
  final PluginHostTransport transport;
  final SchedulerBindings bindings;
  final void Function() changed;
  final _queues = <String, Serial>{};

  Future<T> _serialized<T>(String owner, Future<T> Function() work) =>
      _queues.putIfAbsent(owner, Serial.new).run(work);

  Future<void> _acknowledge(String owner, Host host) async {
    await transport(host, owner, 'pause_scope', {});
    await bindings.set(
      owner,
      host.id,
      const SchedulerBinding(configured: true),
    );
    changed();
  }

  Future<void> pause(String owner, {bool pendingOnly = false}) async {
    final registered = (await bindings.read())[owner] ?? {};
    final configured = registered.entries
        .where(
          (entry) =>
              entry.value.configured && (!pendingOnly || entry.value.pending),
        )
        .map((entry) => entry.key)
        .toList();
    if (configured.isEmpty) return;
    for (final host in configured) {
      await bindings.set(
        owner,
        host,
        const SchedulerBinding(configured: true, pending: true),
      );
    }
    changed();
    await _serialized(owner, () async {
      final available = {for (final host in await hosts.all()) host.id: host};
      for (final id in configured) {
        final host = available[id];
        if (host == null) continue;
        try {
          await _acknowledge(owner, host);
        } on Object {
          // ignored: the binding stays pending and retryPending acknowledges it later.
        }
      }
    });
    changed();
  }

  Future<void> retryPending() async {
    for (final owner in (await bindings.read()).keys) {
      await pause(owner, pendingOnly: true);
    }
  }

  late final service = PluginHostService(
    operations: const {
      'inspect',
      'setup',
      'list',
      'get',
      'save',
      'pause',
      'resume',
      'run',
      'history',
      'output',
      'cancel',
      'usage',
      'pause_scope',
      'resume_scope',
    },
    deactivate: (plugin) => pause(pluginHostOwner(plugin)),
    reconcile: (activeOwners) async {
      for (final owner in (await bindings.read()).keys) {
        if (!activeOwners.contains(owner)) await pause(owner);
      }
    },
    invoke: (plugin, operation, args, confirm, check, _) async {
      Future<T> checked<T>(Future<T> work) async {
        final value = await work;
        check();
        return value;
      }

      final host = await checked(_pick(hosts, args['host']));
      final owner = pluginHostOwner(plugin);
      final bound = (await checked(bindings.read()))[owner] ?? {};
      if (!bound.containsKey(host.id) || operation == 'setup') {
        final operations = plugin.manifest.hostCapabilities.values
            .where((capability) => capability.service == 'scheduler')
            .expand((capability) => capability.operations)
            .toSet();
        if (!await checked(confirm(host, 'scheduler', operations))) {
          throw const PluginException('Host access was not granted');
        }
        if (!bound.containsKey(host.id)) {
          await checked(bindings.set(owner, host.id, const SchedulerBinding()));
        }
      }
      return _serialized(owner, () async {
        check();
        final binding = (await checked(bindings.read()))[owner]?[host.id];
        if (binding?.pending == true && operation != 'pause_scope') {
          await checked(_acknowledge(owner, host));
        }
        if (operation == 'setup') {
          await checked(
            bindings.set(
              owner,
              host.id,
              const SchedulerBinding(configured: true),
            ),
          );
        }
        final parameters = Map<String, Object?>.of(args)..remove('host');
        final result = await checked(
          transport(host, owner, operation, parameters),
        );
        if (operation == 'inspect' &&
            result['installed'] == true &&
            binding?.configured != true) {
          await bindings.set(
            owner,
            host.id,
            const SchedulerBinding(configured: true),
          );
        }
        return result;
      });
    },
  );
}

final pluginHostRegistryProvider = Provider<PluginHostRegistry>((ref) {
  final hosts = ref.watch(hostRepositoryProvider);
  final scheduler = PluginScheduler(
    hosts,
    ref.watch(schedulerTransportProvider),
    ref.watch(schedulerBindingsProvider),
    () {
      ref.invalidate(pluginHostPendingProvider);
      ref.invalidate(pendingHostPausesProvider);
    },
  );
  return PluginHostRegistry({
    'hosts': PluginHostService(
      operations: const {'list', 'workspaces'},
      invoke: (plugin, operation, args, confirm, check, _) async {
        if (operation == 'workspaces') {
          final host = await _pick(hosts, args['host']);
          if (!await confirm(host, 'hosts', {'workspaces'})) {
            throw const PluginException('Workspace access was not granted');
          }
          check();
          final scan = await ref.read(pathScannerProvider)(host);
          check();
          return switch (scan) {
            PathScanFound(:final directories) => {
              'items': directories.take(200).toList(),
            },
            PathScanFailed(:final reason) => throw PluginException(reason),
            _ => throw const PluginException('Workspace scan did not finish'),
          };
        }
        return {
          'items': [
            for (final host in await hosts.all())
              {'id': host.id, 'name': host.name},
          ],
        };
      },
    ),
    'scheduler': scheduler.service,
    'run': pluginRunService(
      hosts,
      ref.watch(pluginEngineProvider),
      ref.watch(pluginRunHostsProvider),
    ),
    'agents': PluginHostService(
      operations: const {'list', 'answer', 'open'},
      changes: agentsFeedProvider,
      hold: () {
        final held = ref.read(pluginAgentsHeldProvider.notifier);
        held.state++;
        return () {
          if (held.mounted) held.state--;
        };
      },
      invoke: (plugin, operation, args, confirm, check, gesture) async {
        final feed = ref.read(agentsFeedProvider).value;
        if (operation == 'list') return pluginAgentList(feed, DateTime.now());
        if (gesture == null || !gesture.take()) {
          throw const PluginException(
            'Agents are answered and opened only from a tap',
          );
        }
        final found = [
          for (final outcome in feed?.outcomes ?? const <HostOutcome>[])
            for (final agent in outcome.agents)
              if (operation == 'answer'
                  ? agent.approval?.id == args['approval']
                  : pluginAgentId(outcome.host, agent) == args['id'])
                (host: outcome.host, agent: agent),
        ].firstOrNull;
        if (found == null) {
          throw PluginException(
            operation == 'answer'
                ? 'This approval is no longer pending'
                : 'This session is gone',
          );
        }
        if (operation == 'open') {
          gesture.open(found.host, found.agent);
          return {'opened': true};
        }
        final allow = args['allow'];
        if (allow is! bool) {
          throw const PluginException('Answer with allow true or false');
        }
        final engine = await ref.read(engineOpenProvider)(found.host);
        try {
          check();
          await engine.answer(found.agent.approval!.id, allow: allow);
        } on EngineRefused catch (error) {
          throw PluginException(
            error.notFound ? 'Already answered' : 'The engine refused',
          );
        } finally {
          engine.session.close();
        }
        return {'answer': allow ? 'allowed' : 'denied'};
      },
    ),
  }, retryPending: scheduler.retryPending);
});

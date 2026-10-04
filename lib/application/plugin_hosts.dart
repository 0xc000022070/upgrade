import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:dazzle_luau/data_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/repositories/host_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/host_keys.dart';
import '../platform/host_links.dart';
import '../platform/plugins/manifest.dart';
import '../platform/plugins/store.dart';
import '../platform/ssh_settle.dart';
import 'agents.dart';
import 'path_scan.dart';

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

class PluginHostService {
  const PluginHostService({
    required this.operations,
    required this.invoke,
    this.deactivate,
  });
  final Set<String> operations;
  final Future<Object?> Function(
    InstalledPlugin plugin,
    String operation,
    Map<String, Object?> args,
    PluginHostConfirm confirm,
    void Function() check,
  )
  invoke;
  final Future<void> Function(InstalledPlugin plugin)? deactivate;
}

class PluginHostUsage {
  int calls = 0;
  int failed = 0;
  int elapsedMicros = 0;
  int sentBytes = 0;
  int receivedBytes = 0;
}

class PluginHostRegistry {
  PluginHostRegistry(this.services, {this.retryPending, this.reconcile});
  final Map<String, PluginHostService> services;
  final Future<void> Function()? retryPending;
  final Future<void> Function(Set<String> activeOwners)? reconcile;
  final _usage = <String, Map<String, PluginHostUsage>>{};
  Map<String, PluginHostUsage> usage(InstalledPlugin plugin) =>
      Map.unmodifiable(_usage[pluginHostOwner(plugin)] ?? {});
  Future<Object?> invoke(
    InstalledPlugin plugin,
    Map<String, Object?> effect,
    PluginHostConfirm confirm,
    void Function() check,
  ) async {
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
      final result = await _invoke(plugin, effect, confirm, check);
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
    );
    check();
    return result;
  }

  Future<void> deactivate(InstalledPlugin plugin) async {
    for (final service
        in plugin.manifest.hostCapabilities.values
            .map((c) => c.service)
            .toSet()) {
      await services[service]?.deactivate?.call(plugin);
    }
  }
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
  final keys = ref.watch(privateKeyStoreProvider);
  final links = ref.read(hostLinksProvider);
  return (host, scope, operation, args) async {
    if (host.hostKey == null) {
      throw const PluginException(
        'Verify the host key in HOSTS before connecting',
      );
    }
    final privateKey = await keys.read(host.keyId);
    if (privateKey == null) {
      throw const PluginException('Host private key is unavailable');
    }
    final HostLease lease;
    try {
      lease = await links.lease(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
      );
    } on HerdrFailure catch (error) {
      throw PluginException(error.reason(host.name));
    }
    try {
      return await scheduleOver(
        lease.client,
        host.user,
        scope,
        operation,
        args,
      );
    } on SSHChannelOpenError {
      throw const PluginException('Host busy');
    } on TimeoutException {
      unawaited(lease.suspect());
      rethrow;
    } on SSHError {
      unawaited(lease.suspect());
      rethrow;
    } finally {
      lease.release();
    }
  };
});

@visibleForTesting
Future<Map<String, Object?>> scheduleOver(
  SSHClient client,
  String owner,
  String scope,
  String operation,
  Map<String, Object?> args,
) async {
  final session = await openWithin(
    client.execute('dazzle-engine'),
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
      session.stdout.forEach((bytes) => append(output, bytes, 512 * 1024)),
      session.stderr.forEach((bytes) => append(errors, bytes, 16 * 1024)),
    ]);
    session.stdin.add(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'service': 'schedule/1',
            'op': operation,
            'owner': owner,
            'args': wholeNumbers({...args, 'scope': scope}),
          }),
        ),
      ),
    );
    await session.stdin.close();
    await exchange.timeout(const Duration(seconds: 45));
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
        throw const PluginException('This host has no dazzle-engine installed');
      }
      throw PluginException('Host engine did not answer. $complaint');
    }
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
          : 'Host scheduling failed';
      throw PluginException(
        failure['kind'] == 'unsupported'
            ? "This host's engine does not carry scheduling. $message"
            : message,
      );
    }
    final result = response['result'];
    if (result is! Map<String, Object?>) {
      throw const PluginException('Invalid engine result');
    }
    return result;
  } finally {
    endExec(session);
  }
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
  Future<void> _tail = Future.value();
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
    final changed = _tail.then((_) async {
      final state = await read();
      (state[owner] ??= {})[host] = binding;
      final target = await file();
      await target.parent.create(recursive: true);
      final temporary = File('${target.path}.next');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'owners': state}),
        flush: true,
      );
      await temporary.rename(target.path);
    });
    _tail = changed.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return changed;
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

final pluginHostRegistryProvider = Provider<PluginHostRegistry>((ref) {
  final hosts = ref.watch(hostRepositoryProvider);
  final transport = ref.watch(schedulerTransportProvider);
  final bindings = ref.watch(schedulerBindingsProvider);
  final queues = <String, Future<void>>{};
  Future<T> serialized<T>(String owner, Future<T> Function() work) {
    final result = (queues[owner] ?? Future<void>.value()).then((_) => work());
    queues[owner] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
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
    ref.invalidate(pluginHostPendingProvider);
    ref.invalidate(pendingHostPausesProvider);
    await serialized(owner, () async {
      final available = {for (final host in await hosts.all()) host.id: host};
      for (final id in configured) {
        final host = available[id];
        if (host == null) continue;
        try {
          await transport(host, owner, 'pause_scope', {});
          await bindings.set(
            owner,
            id,
            const SchedulerBinding(configured: true),
          );
        } on Object {
          // A lost connection cannot acknowledge remote cancellation.
        }
      }
    });
    ref.invalidate(pluginHostPendingProvider);
    ref.invalidate(pendingHostPausesProvider);
  }

  return PluginHostRegistry(
    {
      'hosts': PluginHostService(
        operations: const {'list', 'workspaces'},
        invoke: (plugin, operation, args, confirm, check) async {
          if (operation == 'workspaces') {
            final available = await hosts.all();
            final host = available
                .where((host) => host.id == args['host'])
                .firstOrNull;
            if (host == null) {
              throw const PluginException('Choose an existing host');
            }
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
      'scheduler': PluginHostService(
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
        invoke: (plugin, operation, args, confirm, check) async {
          final hostId = args['host'];
          final available = await hosts.all();
          final matching = available.where((host) => host.id == hostId);
          if (matching.isEmpty) {
            throw const PluginException('Choose an existing host');
          }
          final host = matching.single;
          final owner = pluginHostOwner(plugin);
          final bound = (await bindings.read())[owner] ?? {};
          if (!bound.containsKey(host.id) || operation == 'setup') {
            final operations = plugin.manifest.hostCapabilities.values
                .where((capability) => capability.service == 'scheduler')
                .expand((capability) => capability.operations)
                .toSet();
            if (!await confirm(host, 'scheduler', operations)) {
              throw const PluginException('Host access was not granted');
            }
            check();
            if (!bound.containsKey(host.id)) {
              await bindings.set(owner, host.id, const SchedulerBinding());
            }
          }
          return serialized(owner, () async {
            check();
            final binding = (await bindings.read())[owner]?[host.id];
            if (binding?.pending == true && operation != 'pause_scope') {
              await transport(host, owner, 'pause_scope', {});
              await bindings.set(
                owner,
                host.id,
                const SchedulerBinding(configured: true),
              );
              ref.invalidate(pluginHostPendingProvider);
              ref.invalidate(pendingHostPausesProvider);
              check();
            }
            if (operation == 'setup') {
              await bindings.set(
                owner,
                host.id,
                const SchedulerBinding(configured: true),
              );
            }
            check();
            final parameters = Map<String, Object?>.of(args)..remove('host');
            final result = await transport(host, owner, operation, parameters);
            check();
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
      ),
    },
    retryPending: () async {
      for (final owner in (await bindings.read()).keys) {
        await pause(owner, pendingOnly: true);
      }
    },
    reconcile: (activeOwners) async {
      for (final owner in (await bindings.read()).keys) {
        if (!activeOwners.contains(owner)) await pause(owner);
      }
    },
  );
});

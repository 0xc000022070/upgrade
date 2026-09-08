import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/enums.dart';
import '../data/repositories/host_repository.dart';
import '../data/repositories/key_repository.dart';
import '../data/repositories/path_repository.dart';
import '../platform/bundle_cipher.dart';
import '../platform/host_keys.dart';
import '../platform/keys.dart';
import 'agents.dart';
import 'providers.dart';
import 'reason_lines.dart';

/// What moves between phones: the keys with their private halves, the hosts
/// with everything the phone knows about them, and the paths without their
/// project links. Nothing else — projects, drops, dispatches, tabs, frames and
/// settings are one phone's history and one phone's taste.
class Bundle {
  const Bundle({required this.keys, required this.hosts, required this.paths});

  final List<BundleKey> keys;
  final List<BundleHost> hosts;
  final List<BundlePath> paths;

  BundleCount get count =>
      BundleCount(hosts: hosts.length, keys: keys.length, paths: paths.length);

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  Map<String, Object> toJson() => {
    'keys': [for (final key in keys) key.toJson()],
    'hosts': [for (final host in hosts) host.toJson()],
    'paths': [for (final path in paths) path.toJson()],
  };

  /// A payload that opened under the passphrase but does not read as a bundle
  /// is a file somebody sealed with the app's own envelope around something
  /// else; it gets the same word as a file with no envelope at all.
  static Bundle decode(Uint8List payload) {
    try {
      final json = jsonDecode(utf8.decode(payload));
      if (json is! Map) throw const FormatException();
      return Bundle(
        keys: [for (final key in _list(json['keys'])) BundleKey.fromJson(key)],
        hosts: [
          for (final host in _list(json['hosts'])) BundleHost.fromJson(host),
        ],
        paths: [
          for (final path in _list(json['paths'])) BundlePath.fromJson(path),
        ],
      );
    } on FormatException {
      throw const BundleException(BundleFault.notABundle);
    } on TypeError {
      throw const BundleException(BundleFault.notABundle);
    }
  }

  static List<Map> _list(Object? value) {
    if (value is! List) throw const FormatException();
    return [for (final item in value) item as Map];
  }
}

class BundleKey {
  const BundleKey({required this.key, required this.privateKey});

  final ManagedKey key;

  /// The PEM out of the keystore. The one thing that otherwise never leaves
  /// the phone, and the one thing without which the other phone cannot dial.
  final String privateKey;

  Map<String, Object> toJson() => {
    'id': key.id,
    'name': key.name,
    'publicKey': key.publicKey,
    'fingerprint': key.fingerprint,
    'createdAt': key.createdAt.toUtc().toIso8601String(),
    'privateKey': privateKey,
  };

  static BundleKey fromJson(Map json) => BundleKey(
    key: ManagedKey(
      id: json['id'] as String,
      name: json['name'] as String,
      publicKey: json['publicKey'] as String,
      fingerprint: json['fingerprint'] as String,
      createdAt: _date(json['createdAt']),
    ),
    privateKey: json['privateKey'] as String,
  );
}

class BundleHost {
  const BundleHost({required this.host, required this.integrations});

  final Host host;
  final Set<IntegrationKind> integrations;

  Map<String, Object?> toJson() {
    final pin = host.hostKey;
    return {
      'id': host.id,
      'name': host.name,
      'address': host.address,
      'port': host.port,
      'user': host.user,
      'keyId': host.keyId,
      'hostKey': pin == null
          ? null
          : {
              'type': pin.type,
              'fingerprint': pin.fingerprint,
              'pinnedAt': pin.pinnedAt.toUtc().toIso8601String(),
            },
      'vncPassword': host.vncPassword,
      'integrations': [for (final kind in integrations) kind.wire],
    };
  }

  static BundleHost fromJson(Map json) {
    final pin = json['hostKey'];
    return BundleHost(
      host: Host(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
        port: json['port'] as int,
        user: json['user'] as String,
        keyId: json['keyId'] as String,
        hostKey: pin == null
            ? null
            : PinnedHostKey(
                type: (pin as Map)['type'] as String,
                fingerprint: pin['fingerprint'] as String,
                pinnedAt: _date(pin['pinnedAt']),
              ),
        vncPassword: json['vncPassword'] as String?,
      ),
      integrations: {
        for (final wire in json['integrations'] as List)
          IntegrationKind.fromWire(wire as String),
      },
    );
  }
}

class BundlePath {
  const BundlePath({
    required this.id,
    required this.hostId,
    required this.directory,
    required this.label,
    required this.createdAt,
  });

  final String id;
  final String hostId;
  final String directory;
  final String label;
  final DateTime createdAt;

  Map<String, Object> toJson() => {
    'id': id,
    'hostId': hostId,
    'directory': directory,
    'label': label,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static BundlePath fromJson(Map json) => BundlePath(
    id: json['id'] as String,
    hostId: json['hostId'] as String,
    directory: json['directory'] as String,
    label: json['label'] as String,
    createdAt: _date(json['createdAt']),
  );
}

DateTime _date(Object? value) => DateTime.parse(value as String);

/// What a bundle holds, as the panel says it: `2 HOSTS · 1 KEY · 5 PATHS`.
class BundleCount {
  const BundleCount({
    required this.hosts,
    required this.keys,
    required this.paths,
  });

  final int hosts;
  final int keys;
  final int paths;

  String get words =>
      '${_plural(hosts, 'HOST')} · ${_plural(keys, 'KEY')} · '
      '${_plural(paths, 'PATH')}';

  static String _plural(int n, String noun) =>
      n == 1 ? '1 $noun' : '$n ${noun}S';
}

/// Runs a body as one write, or as nothing special where there is no
/// database to speak of.
typedef Atomically = Future<T> Function<T>(Future<T> Function() body);

Future<T> _plain<T>(Future<T> Function() body) => body();

/// Gathers a bundle off this phone and lands one on it.
class BundleTransfer {
  const BundleTransfer({
    required this.keys,
    required this.hosts,
    required this.paths,
    required this.store,
    this.atomically = _plain,
  });

  final KeyRepository keys;
  final HostRepository hosts;
  final PathRepository paths;
  final PrivateKeyStore store;
  final Atomically atomically;

  /// Everything that would let another phone dial these hosts. A key row whose
  /// private half is gone from the keystore is skipped: it could not dial here
  /// either.
  Future<Bundle> gather() async {
    final gathered = <BundleKey>[];
    for (final key in await keys.all()) {
      final privateKey = await store.read(key.id);
      if (privateKey == null) continue;
      gathered.add(BundleKey(key: key, privateKey: privateKey));
    }
    final machines = <BundleHost>[];
    final directories = <BundlePath>[];
    for (final host in await hosts.all()) {
      machines.add(
        BundleHost(
          host: host,
          integrations: await hosts.watchIntegrations(host.id).first,
        ),
      );
      for (final path in await paths.listForHost(host.id)) {
        directories.add(
          BundlePath(
            id: path.id,
            hostId: host.id,
            directory: path.directory,
            label: path.label,
            createdAt: path.createdAt,
          ),
        );
      }
    }
    return Bundle(keys: gathered, hosts: machines, paths: directories);
  }

  /// Merges by id and deletes nothing. Refused whole when a host names a key
  /// neither the bundle nor the phone has: that host could never dial.
  ///
  /// Private keys go to the keystore before the rows go to the database. A
  /// private key with no row is inert; a row with no private key is a host
  /// that cannot dial.
  Future<BundleCount> apply(Bundle bundle) async {
    final known = {
      for (final key in await keys.all()) key.id,
      for (final key in bundle.keys) key.key.id,
    };
    for (final host in bundle.hosts) {
      if (!known.contains(host.host.keyId)) {
        throw const BundleException(BundleFault.incomplete);
      }
    }
    for (final key in bundle.keys) {
      await store.write(key.key.id, key.privateKey);
    }
    await atomically(() async {
      for (final key in bundle.keys) {
        await keys.save(key.key);
      }
      for (final entry in bundle.hosts) {
        final host = entry.host;
        await hosts.save(host);
        final pin = host.hostKey;
        if (pin != null) await hosts.pinHostKey(host.id, pin);
        for (final kind in IntegrationKind.values) {
          await hosts.setIntegration(
            host.id,
            kind,
            entry.integrations.contains(kind),
          );
        }
      }
      for (final path in bundle.paths) {
        await paths.put(
          AgentPath(
            id: path.id,
            hostId: path.hostId,
            directory: path.directory,
            label: path.label,
            createdAt: path.createdAt,
          ),
        );
      }
    });
    return bundle.count;
  }
}

/// `spectacle-2026-09-08.bundle`: the picker's suggested name.
String bundleFileName(DateTime now) {
  final day = now.toIso8601String().substring(0, 10);
  return 'spectacle-$day.bundle';
}

/// The panel's word for each way a bundle did not move.
ReasonLine bundleLine(BundleFault fault) => switch (fault) {
  BundleFault.notABundle => ReasonLine.notABundle,
  BundleFault.newerBundle => ReasonLine.newerBundle,
  BundleFault.wrongPassphrase => ReasonLine.wrongPassphrase,
  BundleFault.incomplete => ReasonLine.bundleIncomplete,
  BundleFault.noPicker => ReasonLine.noPicker,
};

/// The derivation runs off the UI isolate: 64 MiB of Argon2id is a second or
/// two the frame would otherwise stall for.
final bundleCipherProvider = Provider<BundleCipher>(
  (ref) => BundleCipher(run: (job) => compute(deriveBundleKey, job)),
);

final bundleTransferProvider = Provider<BundleTransfer>((ref) {
  final db = ref.watch(databaseProvider);
  return BundleTransfer(
    keys: ref.watch(keyRepositoryProvider),
    hosts: ref.watch(hostRepositoryProvider),
    paths: ref.watch(pathRepositoryProvider),
    store: ref.watch(privateKeyStoreProvider),
    atomically: db.transaction,
  );
});

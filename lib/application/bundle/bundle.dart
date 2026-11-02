import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/raw_tables.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/platform/files/attachment_store.dart';
import 'package:upgrade/platform/bundle_cipher.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/application/phone_linux.dart';

class Bundle {
  const Bundle({
    required this.keys,
    required this.hosts,
    required this.paths,
    this.rows = const {},
    this.files = const {},
  });

  final List<BundleKey> keys;
  final List<BundleHost> hosts;
  final List<BundlePath> paths;

  final Map<String, List<Map<String, Object?>>> rows;

  final Map<String, Uint8List> files;

  BundleCount get count => BundleCount(
    hosts: hosts.length,
    keys: keys.length,
    paths: paths.length,
    rows: rows.values.fold(0, (total, table) => total + table.length),
    images: files.length,
  );

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  Map<String, Object> toJson() => {
    'keys': [for (final key in keys) key.toJson()],
    'hosts': [for (final host in hosts) host.toJson()],
    'paths': [for (final path in paths) path.toJson()],
    'rows': rows,
    'files': {
      for (final file in files.entries) file.key: base64Encode(file.value),
    },
  };

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
        rows: _rows(json['rows']),
        files: _files(json['files']),
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

  static Map<String, List<Map<String, Object?>>> _rows(Object? value) {
    if (value == null) return const {};
    if (value is! Map) throw const FormatException();
    return {
      for (final table in value.entries)
        table.key as String: [
          for (final row in _list(table.value))
            {for (final cell in row.entries) cell.key as String: cell.value},
        ],
    };
  }

  static Map<String, Uint8List> _files(Object? value) {
    if (value == null) return const {};
    if (value is! Map) throw const FormatException();
    return {
      for (final file in value.entries)
        file.key as String: base64Decode(file.value as String),
    };
  }
}

class BundleKey {
  const BundleKey({required this.key, required this.privateKey});

  final ManagedKey key;

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
      'vncUsername': host.vncUsername,
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
        vncUsername: json['vncUsername'] as String?,
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
    this.projectId,
  });

  final String id;
  final String hostId;
  final String directory;
  final String label;
  final DateTime createdAt;

  final String? projectId;

  Map<String, Object?> toJson() => {
    'id': id,
    'hostId': hostId,
    'directory': directory,
    'label': label,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'projectId': projectId,
  };

  static BundlePath fromJson(Map json) => BundlePath(
    id: json['id'] as String,
    hostId: json['hostId'] as String,
    directory: json['directory'] as String,
    label: json['label'] as String,
    createdAt: _date(json['createdAt']),
    projectId: json['projectId'] as String?,
  );
}

DateTime _date(Object? value) => DateTime.parse(value as String);

class BundleCount {
  const BundleCount({
    required this.hosts,
    required this.keys,
    required this.paths,
    this.rows = 0,
    this.images = 0,
  });

  final int hosts;
  final int keys;
  final int paths;
  final int rows;
  final int images;

  String get words => [
    _plural(hosts, 'HOST'),
    _plural(keys, 'KEY'),
    _plural(paths, 'PATH'),
    if (rows > 0) _plural(rows, 'ROW'),
    if (images > 0) _plural(images, 'IMAGE'),
  ].join(' · ');

  static String _plural(int n, String noun) =>
      n == 1 ? '1 $noun' : '$n ${noun}S';
}

typedef Atomically = Future<T> Function<T>(Future<T> Function() body);

Future<T> _plain<T>(Future<T> Function() body) => body();

class BundleTransfer {
  const BundleTransfer({
    required this.keys,
    required this.hosts,
    required this.paths,
    required this.store,
    required this.raw,
    required this.attachments,
    this.atomically = _plain,
  });

  final KeyRepository keys;
  final HostRepository hosts;
  final PathRepository paths;
  final PrivateKeyStore store;
  final RawTables raw;
  final AttachmentBytes attachments;
  final Atomically atomically;

  Future<Bundle> gather() async {
    final dumped = await raw.dump();
    final local = _phoneLinuxHosts(dumped);
    final allHosts = await hosts.all();
    final kept = [
      for (final host in allHosts)
        if (!local.contains(host.id)) host,
    ];
    final usedKeys = {for (final host in kept) host.keyId};
    final localKeys = {
      for (final host in allHosts)
        if (local.contains(host.id) && !usedKeys.contains(host.keyId))
          host.keyId,
    };
    final gathered = <BundleKey>[];
    for (final key in await keys.all()) {
      if (localKeys.contains(key.id)) continue;
      final privateKey = await store.read(key.id);
      if (privateKey == null) continue;
      gathered.add(BundleKey(key: key, privateKey: privateKey));
    }
    final machines = <BundleHost>[];
    final directories = <BundlePath>[];
    for (final host in kept) {
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
            projectId: path.projectId,
          ),
        );
      }
    }
    final rows = local.isEmpty
        ? dumped
        : {
            for (final table in dumped.entries)
              table.key: [
                for (final row in table.value)
                  if (!local.contains(row['host_id']) &&
                      !(table.key == 'settings' &&
                          row['key'] == SettingsRepository.phoneLinuxHosts))
                    row,
              ],
          };
    return Bundle(
      keys: gathered,
      hosts: machines,
      paths: directories,
      rows: rows,
      files: await _pictures(rows),
    );
  }

  static Set<String> _phoneLinuxHosts(
    Map<String, List<Map<String, Object?>>> rows,
  ) {
    for (final row in rows['settings'] ?? const <Map<String, Object?>>[]) {
      if (row['key'] == SettingsRepository.phoneLinuxHosts) {
        final ids = row['value'];
        if (ids is String) return PhoneLinuxHost.decodeIds(ids).toSet();
      }
    }
    return const {};
  }

  Future<Map<String, Uint8List>> _pictures(
    Map<String, List<Map<String, Object?>>> rows,
  ) async {
    final pictures = <String, Uint8List>{};
    for (final row in rows['attachments'] ?? const []) {
      if (row['kind'] != AttachmentKind.image.name) continue;
      final relative = row['value'];
      if (relative is! String) continue;
      final bytes = await attachments.read(relative);
      if (bytes != null) pictures[relative] = bytes;
    }
    return pictures;
  }

  /// Private keys and attachment bytes go down before the rows: a key or file with no row
  /// is inert, a row with no key is a host that cannot dial.
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
    for (final picture in bundle.files.entries) {
      await attachments.write(picture.key, picture.value);
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
            projectId: path.projectId,
          ),
        );
      }
      // After the curated four, which the other tables reference.
      await raw.restore(bundle.rows);
    });
    return bundle.count;
  }
}

String bundleFileName(DateTime now) {
  final day = now.toIso8601String().substring(0, 10);
  return 'upgrade-$day.bundle';
}

ReasonLine bundleLine(BundleFault fault) => switch (fault) {
  BundleFault.notABundle => ReasonLine.notABundle,
  BundleFault.newerBundle => ReasonLine.newerBundle,
  BundleFault.wrongPassphrase => ReasonLine.wrongPassphrase,
  BundleFault.incomplete => ReasonLine.bundleIncomplete,
  BundleFault.noPicker => ReasonLine.noPicker,
};

/// Off the UI isolate: 64 MiB of Argon2id would stall the frame for a second or two.
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
    raw: RawTables(db),
    attachments: const FileAttachmentBytes(),
    atomically: db.transaction,
  );
}, dependencies: [pathRepositoryProvider]);

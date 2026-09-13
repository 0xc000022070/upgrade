import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/enums.dart';
import '../data/raw_tables.dart';
import '../data/repositories/host_repository.dart';
import '../data/repositories/key_repository.dart';
import '../data/repositories/path_repository.dart';
import '../platform/attachment_store.dart';
import '../platform/bundle_cipher.dart';
import '../platform/host_keys.dart';
import '../platform/keys.dart';
import 'agents.dart';
import 'providers.dart';
import 'reason_lines.dart';

/// What moves between phones: the whole phone. The keys with their private
/// halves and the hosts with everything known about them, mapped by hand
/// because they are assembled out of a keystore and three repositories; every
/// other table as the rows sqlite holds; and the bytes behind each image
/// attachment, which live in a sandbox the far phone does not have.
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

  /// Table name to its rows, for everything outside [curatedTables].
  final Map<String, List<Map<String, Object?>>> rows;

  /// Attachment bytes, under the path the row holds them by.
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

  /// Absent in a bundle written before the file carried the whole phone, which
  /// is the file this app was built to read.
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
    this.projectId,
  });

  final String id;
  final String hostId;
  final String directory;
  final String label;
  final DateTime createdAt;

  /// Travels now that the projects travel with it: the link that used to be
  /// dangling by definition is a link that resolves.
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

/// What a bundle holds, as the panel says it: `2 HOSTS · 1 KEY · 5 PATHS`,
/// with `· 312 ROWS` and `· 4 IMAGES` on the end when the file carries any.
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

  /// Everything on this phone. A key row whose private half is gone from the
  /// keystore is skipped: it could not dial here either.
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
            projectId: path.projectId,
          ),
        );
      }
    }
    final rows = await raw.dump();
    return Bundle(
      keys: gathered,
      hosts: machines,
      paths: directories,
      rows: rows,
      files: await _pictures(rows),
    );
  }

  /// The bytes behind every image attachment in the dump. A row whose file is
  /// gone is left with nothing to carry: the row is the record, and the phone
  /// it lands on shows the same gap this one does.
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

  /// Merges by id and deletes nothing. Refused whole when a host names a key
  /// neither the bundle nor the phone has: that host could never dial.
  ///
  /// Private keys and attachment bytes go down before the rows go to the
  /// database. A private key with no row is inert and a file with no row is a
  /// few kilobytes; a row with no private key is a host that cannot dial, and
  /// a row with no file is a picture that is gone.
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
      // After the curated four, because the tables that reference them —
      // dispatches, shell tabs, attachments — outnumber the one column that
      // points the other way.
      await raw.restore(bundle.rows);
    });
    return bundle.count;
  }
}

/// `dazzle-2026-09-08.bundle`: the picker's suggested name.
String bundleFileName(DateTime now) {
  final day = now.toIso8601String().substring(0, 10);
  return 'dazzle-$day.bundle';
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
    raw: RawTables(db),
    attachments: const FileAttachmentBytes(),
    atomically: db.transaction,
  );
});

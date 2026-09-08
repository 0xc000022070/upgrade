import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pinenacl/x25519.dart' show ByteList, SecretBox;
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/argon2.dart';

/// Every reason a bundle does not move, each its own word on the panel. The
/// first three are the cipher's, the last two belong to the transfer and the
/// picker; they share the type because the panel treats them as one kind.
enum BundleFault {
  notABundle,
  newerBundle,
  wrongPassphrase,
  incomplete,
  noPicker,
}

class BundleException implements Exception {
  const BundleException(this.fault);

  final BundleFault fault;

  @override
  String toString() => 'BundleException(${fault.name})';
}

/// What the passphrase goes through on its way to a key. Carried in the
/// envelope so that a file sealed under one default still opens under a later
/// one; on the way in the envelope's numbers drive the derivation, not ours.
class BundleKdf {
  const BundleKdf({
    required this.salt,
    this.memoryKib = defaultMemoryKib,
    this.iterations = defaultIterations,
    this.lanes = 1,
  });

  static const defaultMemoryKib = 65536;
  static const defaultIterations = 3;

  /// Above this a file is asking the phone to allocate a quarter gigabyte on
  /// somebody else's say-so, and is refused rather than obeyed.
  static const maxMemoryKib = 262144;

  final Uint8List salt;
  final int memoryKib;
  final int iterations;
  final int lanes;

  Map<String, Object> toJson() => {
    'name': 'argon2id',
    'memory': memoryKib,
    'iterations': iterations,
    'lanes': lanes,
    'salt': base64Encode(salt),
  };

  /// Null for anything that is not an argon2id block with sane numbers.
  static BundleKdf? fromJson(Object? json) {
    if (json is! Map) return null;
    final memory = json['memory'];
    final iterations = json['iterations'];
    final lanes = json['lanes'];
    final salt = json['salt'];
    if (json['name'] != 'argon2id' ||
        memory is! int ||
        iterations is! int ||
        lanes is! int ||
        salt is! String) {
      return null;
    }
    if (memory < 8 * lanes ||
        memory > maxMemoryKib ||
        iterations < 1 ||
        lanes < 1 ||
        lanes > 4) {
      return null;
    }
    final Uint8List saltBytes;
    try {
      saltBytes = base64Decode(salt);
    } on FormatException {
      return null;
    }
    if (saltBytes.length < 8) return null;
    return BundleKdf(
      salt: saltBytes,
      memoryKib: memory,
      iterations: iterations,
      lanes: lanes,
    );
  }
}

/// One derivation, as a value that can cross an isolate boundary: strings and
/// byte lists only, so the app can run it under `compute` and the tests inline.
class KdfJob {
  const KdfJob({required this.passphrase, required this.kdf});

  final String passphrase;
  final BundleKdf kdf;
}

/// The Argon2id run itself. Top-level so that `compute` can take it.
Uint8List deriveBundleKey(KdfJob job) {
  final kdf = job.kdf;
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        kdf.salt,
        desiredKeyLength: SecretBox.keyLength,
        iterations: kdf.iterations,
        memory: kdf.memoryKib,
        lanes: kdf.lanes,
        version: Argon2Parameters.ARGON2_VERSION_13,
      ),
    );
  return generator.process(Uint8List.fromList(utf8.encode(job.passphrase)));
}

typedef KdfRunner = Future<Uint8List> Function(KdfJob job);

Future<Uint8List> _inline(KdfJob job) async => deriveBundleKey(job);

/// Seals a payload under a passphrase and opens it again.
///
/// The envelope is JSON so that a curious `cat` says what the file is: a
/// marker, a version, the KDF and its parameters, then salt, nonce and box in
/// base64. The box is NaCl's secretbox — XSalsa20 with a Poly1305 tag — so a
/// wrong passphrase and an edited box fail the same way, on the tag.
class BundleCipher {
  BundleCipher({
    this.memoryKib = BundleKdf.defaultMemoryKib,
    this.iterations = BundleKdf.defaultIterations,
    this.run = _inline,
    Random? random,
  }) : _random = random ?? Random.secure();

  static const marker = 'bundle';
  static const version = 1;
  static const _saltLength = 16;
  static const _nonceLength = 24;

  /// What this phone seals under. Opening reads the file's own numbers.
  final int memoryKib;
  final int iterations;

  /// Where the derivation runs: inline by default, off the UI isolate in the
  /// app.
  final KdfRunner run;
  final Random _random;

  Future<Uint8List> seal(Uint8List payload, String passphrase) async {
    final kdf = BundleKdf(
      salt: _bytes(_saltLength),
      memoryKib: memoryKib,
      iterations: iterations,
    );
    final key = await run(KdfJob(passphrase: passphrase, kdf: kdf));
    final nonce = _bytes(_nonceLength);
    final box = SecretBox(key).encrypt(payload, nonce: nonce).cipherText;
    final envelope = <String, Object>{
      'spectacle': marker,
      'version': version,
      'kdf': kdf.toJson(),
      'nonce': base64Encode(nonce),
      'box': base64Encode(Uint8List.fromList(box)),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  Future<Uint8List> open(Uint8List file, String passphrase) async {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(file));
    } on FormatException {
      throw const BundleException(BundleFault.notABundle);
    }
    if (json is! Map || json['spectacle'] != marker) {
      throw const BundleException(BundleFault.notABundle);
    }
    final fileVersion = json['version'];
    if (fileVersion is! int || fileVersion < 1) {
      throw const BundleException(BundleFault.notABundle);
    }
    if (fileVersion > version) {
      throw const BundleException(BundleFault.newerBundle);
    }
    final kdf = BundleKdf.fromJson(json['kdf']);
    final nonce = _decode(json['nonce']);
    final box = _decode(json['box']);
    if (kdf == null ||
        nonce == null ||
        nonce.length != _nonceLength ||
        box == null ||
        box.length < SecretBox.macBytes) {
      throw const BundleException(BundleFault.notABundle);
    }
    final key = await run(KdfJob(passphrase: passphrase, kdf: kdf));
    try {
      return SecretBox(key).decrypt(ByteList(box), nonce: nonce);
    } catch (_) {
      // A failed tag is thrown as a bare string by the library, so nothing
      // narrower than this catches it.
      throw const BundleException(BundleFault.wrongPassphrase);
    }
  }

  Uint8List _bytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

  static Uint8List? _decode(Object? value) {
    if (value is! String) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }
}

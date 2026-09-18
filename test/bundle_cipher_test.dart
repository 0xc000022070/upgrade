import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/bundle_cipher.dart';

// Small enough to run in a test, well below what the app seals under; the envelope
// carries the numbers, so the opener does not care which.
BundleCipher _cipher({KdfRunner? run}) => BundleCipher(
  memoryKib: 64,
  iterations: 1,
  run: run ?? (job) async => deriveBundleKey(job),
);

final _payload = Uint8List.fromList(utf8.encode('{"keys":[],"hosts":[]}'));

Map<String, Object?> _envelope(Uint8List file) =>
    (jsonDecode(utf8.decode(file)) as Map).cast<String, Object?>();

Uint8List _bytes(Map<String, Object?> envelope) =>
    Uint8List.fromList(utf8.encode(jsonEncode(envelope)));

Future<BundleFault> _faultOf(Future<Uint8List> Function() open) async {
  try {
    await open();
  } on BundleException catch (e) {
    return e.fault;
  }
  fail('opened');
}

void main() {
  test('seal then open with the same passphrase is the payload', () async {
    final cipher = _cipher();
    final file = await cipher.seal(_payload, 'correct horse');
    expect(await cipher.open(file, 'correct horse'), _payload);

    final envelope = _envelope(file);
    expect(envelope['dazzle'], 'bundle');
    expect(envelope['version'], 1);
    final kdf = envelope['kdf'] as Map;
    expect(kdf['name'], 'argon2id');
    expect(kdf['memory'], 64);
    expect(kdf['iterations'], 1);
    expect(utf8.decode(file), isNot(contains('keys')));
  });

  test('two seals of the same payload differ in salt and nonce', () async {
    final cipher = _cipher();
    final a = _envelope(await cipher.seal(_payload, 'p'));
    final b = _envelope(await cipher.seal(_payload, 'p'));
    expect((a['kdf'] as Map)['salt'], isNot((b['kdf'] as Map)['salt']));
    expect(a['nonce'], isNot(b['nonce']));
    expect(a['box'], isNot(b['box']));
  });

  test('a wrong passphrase is refused as such', () async {
    final cipher = _cipher();
    final file = await cipher.seal(_payload, 'correct horse');
    expect(
      await _faultOf(() => cipher.open(file, 'battery staple')),
      BundleFault.wrongPassphrase,
    );
  });

  test('a flipped byte in the box fails the same way', () async {
    final cipher = _cipher();
    final envelope = _envelope(await cipher.seal(_payload, 'p'));
    final box = base64Decode(envelope['box'] as String);
    box[box.length - 1] ^= 0x01;
    envelope['box'] = base64Encode(box);
    expect(
      await _faultOf(() => cipher.open(_bytes(envelope), 'p')),
      BundleFault.wrongPassphrase,
    );
  });

  test('a file without the marker is not a bundle', () async {
    final cipher = _cipher();
    expect(
      await _faultOf(
        () => cipher.open(Uint8List.fromList(utf8.encode('hello')), 'p'),
      ),
      BundleFault.notABundle,
    );
    expect(
      await _faultOf(
        () => cipher.open(_bytes({'dazzle': 'note', 'version': 1}), 'p'),
      ),
      BundleFault.notABundle,
    );
    final envelope = _envelope(await cipher.seal(_payload, 'p'));
    envelope.remove('nonce');
    expect(
      await _faultOf(() => cipher.open(_bytes(envelope), 'p')),
      BundleFault.notABundle,
    );
  });

  test('a file sealed under the old name still opens', () async {
    final cipher = _cipher();
    final envelope = _envelope(await cipher.seal(_payload, 'p'));
    envelope.remove('dazzle');
    envelope['spectacle'] = 'bundle';
    expect(await cipher.open(_bytes(envelope), 'p'), _payload);

    envelope.remove('spectacle');
    envelope['hotline'] = 'bundle';
    expect(
      await _faultOf(() => cipher.open(_bytes(envelope), 'p')),
      BundleFault.notABundle,
    );
  });

  test('a version above the app is a newer bundle', () async {
    final cipher = _cipher();
    final envelope = _envelope(await cipher.seal(_payload, 'p'));
    envelope['version'] = 2;
    expect(
      await _faultOf(() => cipher.open(_bytes(envelope), 'p')),
      BundleFault.newerBundle,
    );
  });

  test('the envelope parameters drive the opening', () async {
    final sealed = await _cipher().seal(_payload, 'p');
    final seen = <KdfJob>[];
    final opener = BundleCipher(
      memoryKib: 128,
      iterations: 2,
      run: (job) async {
        seen.add(job);
        return deriveBundleKey(job);
      },
    );
    expect(await opener.open(sealed, 'p'), _payload);
    expect(seen.single.kdf.memoryKib, 64);
    expect(seen.single.kdf.iterations, 1);
  });

  test('an oversized memory parameter is refused rather than obeyed', () async {
    final cipher = _cipher();
    final envelope = _envelope(await cipher.seal(_payload, 'p'));
    final kdf = (envelope['kdf'] as Map).cast<String, Object?>();
    kdf['memory'] = BundleKdf.maxMemoryKib + 1;
    envelope['kdf'] = kdf;
    var ran = false;
    final opener = _cipher(
      run: (job) async {
        ran = true;
        return deriveBundleKey(job);
      },
    );
    expect(
      await _faultOf(() => opener.open(_bytes(envelope), 'p')),
      BundleFault.notABundle,
    );
    expect(ran, isFalse);
  });
}

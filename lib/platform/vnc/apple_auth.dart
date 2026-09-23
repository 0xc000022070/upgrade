import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

Uint8List appleAuthResponse({
  required String username,
  required String password,
  required int generator,
  required Uint8List modulus,
  required Uint8List serverPublic,
  BigInt? privateKey,
  Uint8List Function(int length)? randomBytes,
}) {
  if (modulus.isEmpty || modulus.length != serverPublic.length) {
    throw const FormatException('invalid Apple DH key length');
  }
  final prime = _decode(modulus);
  final peer = _decode(serverPublic);
  if (generator < 2 || prime <= BigInt.from(4)) {
    throw const FormatException('invalid Apple DH parameters');
  }
  if (peer <= BigInt.one || peer >= prime - BigInt.one) {
    throw const FormatException('invalid Apple DH public key');
  }

  final bytes = randomBytes ?? _secureBytes;
  final exponent =
      privateKey ??
      (_decode(bytes(modulus.length)) % (prime - BigInt.from(3)) +
          BigInt.from(2));
  if (exponent <= BigInt.one || exponent >= prime - BigInt.one) {
    throw const FormatException('invalid Apple DH private key');
  }

  final public = BigInt.from(generator).modPow(exponent, prime);
  final shared = peer.modPow(exponent, prime);
  final key = MD5Digest().process(_encode(shared, modulus.length));

  final clear = bytes(128);
  _writeCredential(clear, 0, username);
  _writeCredential(clear, 64, password);

  final aes = AESEngine()..init(true, KeyParameter(key));
  final encrypted = Uint8List(128);
  for (var offset = 0; offset < clear.length; offset += aes.blockSize) {
    aes.processBlock(clear, offset, encrypted, offset);
  }
  return Uint8List.fromList([...encrypted, ..._encode(public, modulus.length)]);
}

void _writeCredential(Uint8List target, int offset, String value) {
  final encoded = utf8.encode(value);
  final length = min(encoded.length, 63);
  target.setRange(offset, offset + length, encoded);
  target[offset + length] = 0;
}

Uint8List _secureBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

BigInt _decode(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _encode(BigInt value, int length) {
  final out = Uint8List(length);
  var remaining = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  if (remaining != BigInt.zero) {
    throw const FormatException('Apple DH value exceeds key length');
  }
  return out;
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The key is the password cut or zero-padded to 8 bytes with the bits of every byte
/// reversed. The original VNC server took the key bytes in that mirrored order and every
/// server since has kept it, so a straight DES key fails against all of them.
Uint8List vncAuthResponse(String password, List<int> challenge) {
  final bytes = utf8.encode(password);
  final key = Uint8List(8);
  for (var i = 0; i < 8 && i < bytes.length; i++) {
    key[i] = _mirror(bytes[i]);
  }
  // pointycastle ships no single-DES engine. Triple DES with the same key three times
  // encrypts, decrypts and encrypts again under one key, which is single DES.
  final des = DESedeEngine()
    ..init(true, KeyParameter(Uint8List.fromList([...key, ...key, ...key])));
  final input = Uint8List.fromList(challenge);
  final out = Uint8List(16);
  des.processBlock(input, 0, out, 0);
  des.processBlock(input, 8, out, 8);
  return out;
}

int _mirror(int byte) {
  var mirrored = 0;
  for (var i = 0; i < 8; i++) {
    mirrored = (mirrored << 1) | ((byte >> i) & 1);
  }
  return mirrored;
}

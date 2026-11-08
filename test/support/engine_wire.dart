import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:upgrade/platform/shell/engine_channel.dart';

const _clientInput = 1 << 0;
const _clientClose = 1 << 1;
const _serverData = 1 << 0;
const _serverJump = 1 << 1;
const _recordHeader = 5;

EngineClientPacket? decodeClientPacket(Uint8List bytes) {
  if (bytes.length < engineClientHeader) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint8(0) != engineWireVersion) return null;
  final flags = view.getUint8(1);
  final carries = flags & _clientInput != 0;
  if (carries && bytes.length < engineClientHeader + 8) return null;
  return EngineClientPacket(
    close: flags & _clientClose != 0,
    timestamp: view.getUint16(2),
    timestampReply: view.getUint16(4),
    ack: view.getUint64(6),
    keyframe: view.getUint32(14),
    sizeGen: view.getUint32(18),
    size: EngineSize(
      view.getUint16(22),
      view.getUint16(24),
      widthPx: view.getUint16(26),
      heightPx: view.getUint16(28),
    ),
    inputOffset: carries ? view.getUint64(engineClientHeader) : null,
    input: carries
        ? Uint8List.fromList(bytes.sublist(engineClientHeader + 8))
        : null,
  );
}

Uint8List encodeServerPacket(EngineServerPacket packet) {
  final data = packet.data;
  final offset = packet.offset;
  final carries = data != null && offset != null;
  final out = ByteData(engineServerHeader + (carries ? 8 + data.length : 0));
  out
    ..setUint8(0, engineWireVersion)
    ..setUint8(1, (carries ? _serverData : 0) | (packet.jump ? _serverJump : 0))
    ..setUint16(2, packet.timestamp & 0xffff)
    ..setUint16(4, packet.timestampReply & 0xffff)
    ..setUint64(6, packet.inputAck)
    ..setUint32(14, packet.sizeGen)
    ..setUint64(18, packet.streamEnd);
  final bytes = out.buffer.asUint8List();
  if (carries) {
    out.setUint64(engineServerHeader, offset);
    bytes.setAll(engineServerHeader + 8, data);
  }
  return bytes;
}

Uint8List sealEngineServerPacket(
  MoshPacketCipher cipher,
  int sequence,
  Uint8List plaintext,
) {
  final wire = Uint8List(8);
  ByteData.sublistView(wire).setUint64(0, sequence);
  wire[0] |= 0x80;
  final sealed = cipher.delegate.seal(
    nonce: MoshNonce.fromWire(wire).aeadBytes,
    plaintext: plaintext,
  );
  return Uint8List(8 + sealed.length)
    ..setAll(0, wire)
    ..setAll(8, sealed);
}

Uint8List engineRecord(int kind, List<int> body) {
  final out = ByteData(_recordHeader + body.length)
    ..setUint8(0, kind)
    ..setUint32(1, body.length);
  return out.buffer.asUint8List()..setAll(_recordHeader, body);
}

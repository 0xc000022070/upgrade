import 'dart:convert';
import 'dart:typed_data';

const messageLimit = 256 * 1024;

Uint8List encodeValue(Object? value) {
  final bytes = BytesBuilder(copy: false);
  void add(List<int> data) {
    if (bytes.length + data.length > messageLimit) {
      throw const FormatException('Plugin message exceeds 256 KiB');
    }
    bytes.add(data);
  }

  void word(int value) => add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void write(Object? value, int depth) {
    if (depth > 32) throw const FormatException('Plugin message is too deep');
    switch (value) {
      case null:
        add([0]);
      case false:
        add([1]);
      case true:
        add([2]);
      case num():
        if (!value.isFinite) throw const FormatException('Non-finite number');
        add([3]);
        add(
          (ByteData(8)..setFloat64(0, value.toDouble(), Endian.little)).buffer
              .asUint8List(),
        );
      case String():
        final encoded = utf8.encode(value);
        add([4]);
        word(encoded.length);
        add(encoded);
      case List<Object?>():
        if (value.length > 4096)
          throw const FormatException('Plugin collection is too large');
        add([5]);
        word(value.length);
        for (final item in value) {
          write(item, depth + 1);
        }
      case Map<String, Object?>():
        if (value.length > 4096)
          throw const FormatException('Plugin collection is too large');
        add([6]);
        word(value.length);
        for (final item in value.entries) {
          write(item.key, depth + 1);
          write(item.value, depth + 1);
        }
      default:
        throw const FormatException('Unsupported plugin message value');
    }
  }

  write(value, 0);
  return bytes.takeBytes();
}

Object? decodeValue(Uint8List bytes) {
  if (bytes.length > messageLimit)
    throw const FormatException('Plugin message exceeds 256 KiB');
  final data = ByteData.sublistView(bytes);
  var at = 0;
  void need(int count) {
    if (count < 0 || at + count > bytes.length)
      throw const FormatException('Truncated plugin message');
  }

  int word() {
    need(4);
    final value = data.getUint32(at, Endian.little);
    at += 4;
    return value;
  }

  Object? read(int depth) {
    if (depth > 32) throw const FormatException('Plugin message is too deep');
    need(1);
    switch (bytes[at++]) {
      case 0:
        return null;
      case 1:
        return false;
      case 2:
        return true;
      case 3:
        need(8);
        final value = data.getFloat64(at, Endian.little);
        at += 8;
        if (!value.isFinite) throw const FormatException('Non-finite number');
        return value;
      case 4:
        final length = word();
        need(length);
        final value = utf8.decode(bytes.sublist(at, at + length));
        at += length;
        return value;
      case 5:
        final count = word();
        if (count > 4096)
          throw const FormatException('Plugin collection is too large');
        return [for (var i = 0; i < count; i++) read(depth + 1)];
      case 6:
        final count = word();
        if (count > 4096)
          throw const FormatException('Plugin collection is too large');
        final result = <String, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = read(depth + 1);
          if (key is! String || result.containsKey(key))
            throw const FormatException('Invalid plugin map key');
          result[key] = read(depth + 1);
        }
        return result;
      default:
        throw const FormatException('Unknown plugin message type');
    }
  }

  final result = read(0);
  if (at != bytes.length)
    throw const FormatException('Trailing plugin message bytes');
  return result;
}

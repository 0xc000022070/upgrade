import 'dart:convert';
import 'dart:typed_data';

class PrivateOscScanner {
  PrivateOscScanner(this.code, this.onSequence)
    : _prefix = utf8.encode('$code;');

  final String code;

  final void Function(List<String> args) onSequence;

  final List<int> _prefix;

  static const _cap = 4096;

  var _state = _State.ground;
  final _payload = BytesBuilder(copy: false);

  void add(Uint8List bytes) {
    for (final byte in bytes) {
      switch (_state) {
        case _State.ground:
          if (byte == 0x1b) _state = _State.escape;
        case _State.escape:
          if (byte == 0x5d) {
            _payload.clear();
            _state = _State.osc;
          } else if (byte != 0x1b) {
            _state = _State.ground;
          }
        case _State.osc:
          if (byte == 0x07) {
            _finish();
          } else if (byte == 0x1b) {
            _state = _State.oscEscape;
          } else {
            _collect(byte);
          }
        case _State.oscEscape:
          if (byte == 0x5c) {
            _finish();
          } else {
            _payload.clear();
            _state = byte == 0x5d ? _State.osc : _State.ground;
          }
        case _State.foreign:
          if (byte == 0x07) {
            _state = _State.ground;
          } else if (byte == 0x1b) {
            _state = _State.escape;
          }
      }
    }
  }

  void _collect(int byte) {
    final length = _payload.length;
    if (length < _prefix.length && byte != _prefix[length]) {
      _payload.clear();
      _state = _State.foreign;
      return;
    }
    if (length >= _cap) {
      _payload.clear();
      _state = _State.foreign;
      return;
    }
    _payload.addByte(byte);
  }

  void _finish() {
    _state = _State.ground;
    final payload = _payload.takeBytes();
    if (payload.length < _prefix.length) return;
    final body = utf8.decode(
      payload.sublist(_prefix.length),
      allowMalformed: true,
    );
    onSequence(body.split(';'));
  }
}

enum _State { ground, escape, osc, oscEscape, foreign }

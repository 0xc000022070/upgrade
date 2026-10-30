import 'dart:convert';
import 'dart:typed_data';

import 'package:upgrade/application/agents/agent_kind.dart';

const agentInputPause = Duration(milliseconds: 600);

AgentKind? foregroundAgent(String processes) {
  final lines = const LineSplitter()
      .convert(processes)
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length != 1) return null;
  final fields = lines.single.split('\t');
  if (fields.length != 3) return null;
  for (final kind in AgentKind.all) {
    if (kind.matchesForegroundProcess(fields[0], fields[1], fields[2])) {
      return kind;
    }
  }
  return null;
}

class AgentInputActivity {
  final _characters = <bool>[];
  var _nonBlank = 0;
  var _pasting = false;
  var _unknown = false;

  bool get hasText => !_unknown && _nonBlank > 0;

  void clear() {
    _characters.clear();
    _nonBlank = 0;
    _pasting = false;
    _unknown = false;
  }

  void observe(Uint8List bytes) {
    late final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      _loseTrack();
      return;
    }
    for (var index = 0; index < text.length;) {
      if (text.startsWith('\x1b[200~', index)) {
        _pasting = true;
        index += 6;
        continue;
      }
      if (text.startsWith('\x1b[201~', index)) {
        _pasting = false;
        index += 6;
        continue;
      }
      var rune = text.codeUnitAt(index++);
      if (rune >= 0xd800 && rune <= 0xdbff && index < text.length) {
        rune =
            0x10000 +
            ((rune - 0xd800) << 10) +
            (text.codeUnitAt(index++) - 0xdc00);
      }
      if (!_pasting && rune == 0x1b) {
        _loseTrack();
        if (index < text.length && text.codeUnitAt(index) == 0x5b) {
          index++;
          while (index < text.length) {
            final code = text.codeUnitAt(index++);
            if (code >= 0x40 && code <= 0x7e) break;
          }
        } else if (index < text.length && text.codeUnitAt(index) == 0x4f) {
          index++;
          if (index < text.length) index++;
        } else if (index < text.length) {
          index++;
        }
        continue;
      }
      if (!_pasting && (rune == 0x0a || rune == 0x0d)) {
        clear();
        continue;
      }
      if (!_pasting && (rune == 0x08 || rune == 0x7f)) {
        if (_characters.isNotEmpty && _characters.removeLast()) _nonBlank--;
        continue;
      }
      if (!_pasting && rune < 0x20) {
        _loseTrack();
        continue;
      }
      if (_unknown) _unknown = false;
      if (_characters.length >= 65536) {
        _loseTrack();
        continue;
      }
      final nonBlank = String.fromCharCode(rune).trim().isNotEmpty;
      _characters.add(nonBlank);
      if (nonBlank) _nonBlank++;
    }
  }

  void _loseTrack() {
    _characters.clear();
    _nonBlank = 0;
    _unknown = true;
  }
}

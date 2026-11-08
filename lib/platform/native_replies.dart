import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The request ids and pending completers behind a native library that answers
/// `{"reply": id, ...}` through a callback.
final class NativeReplies {
  NativeReplies(this._free);

  final void Function(Pointer<Utf8>) _free;
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;

  Map<String, Object?> decode(Pointer<Utf8> text) {
    final message = jsonDecode(text.toDartString()) as Map<String, Object?>;
    _free(text);
    return message;
  }

  Completer<Object?>? take(Object? id) => _pending.remove(id);

  Future<Object?> send(
    Map<String, Object?> request,
    void Function(int id, Pointer<Utf8> text) invoke,
  ) {
    final id = _next++;
    final done = Completer<Object?>();
    _pending[id] = done;
    final text = jsonEncode(request).toNativeUtf8();
    invoke(id, text);
    malloc.free(text);
    return done.future;
  }
}

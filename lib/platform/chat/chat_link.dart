import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class ChatLink {
  Future<Object?> call(Map<String, Object?> request);

  Stream<Map<String, Object?>> get events;
}

class ChatException implements Exception {
  const ChatException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef _Callback = Void Function(Pointer<Utf8>);
typedef _Start = Void Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _StartDart = void Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _Call = Void Function(Int64, Pointer<Utf8>);
typedef _CallDart = void Function(int, Pointer<Utf8>);
typedef _Free = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class NativeChatLink implements ChatLink {
  NativeChatLink._(this._call, this._free);

  final _CallDart _call;
  final _FreeDart _free;
  final _pending = <int, Completer<Object?>>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _started = Completer<void>();
  var _next = 0;

  static Future<NativeChatLink>? _link;

  static Future<NativeChatLink> open() => _link ??= _open();

  static Future<NativeChatLink> _open() async {
    if (!Platform.isAndroid) {
      throw const ChatException('Chat runs on Android only');
    }
    final dir = await const MethodChannel('dev.luisnquin.upgrade/device')
        .invokeMethod<String>('chat');
    final library = DynamicLibrary.open('libupgrade_chat.so');
    final link = NativeChatLink._(
      library.lookupFunction<_Call, _CallDart>('upgrade_chat_call'),
      library.lookupFunction<_Free, _FreeDart>('upgrade_chat_free'),
    );
    final callback = NativeCallable<_Callback>.listener(link._receive);
    final path = dir!.toNativeUtf8();
    library.lookupFunction<_Start, _StartDart>('upgrade_chat_start')(
      path,
      callback.nativeFunction,
    );
    malloc.free(path);
    await link._started.future;
    return link;
  }

  void _receive(Pointer<Utf8> text) {
    final message = jsonDecode(text.toDartString()) as Map<String, Object?>;
    _free(text);
    if (message['reply'] case final int id) {
      final pending = _pending.remove(id);
      if (message['error'] case final String error) {
        pending?.completeError(ChatException(error));
      } else {
        pending?.complete(message['ok']);
      }
      return;
    }
    if (!_started.isCompleted) {
      switch (message['event']) {
        case 'started':
          _started.complete();
        case 'failed':
          debugPrint('chat: ${message['detail']}');
          _started.completeError(ChatException('${message['error']}'));
      }
    }
    _events.add(message);
  }

  @override
  Future<Object?> call(Map<String, Object?> request) {
    final id = _next++;
    final done = Completer<Object?>();
    _pending[id] = done;
    final text = jsonEncode(request).toNativeUtf8();
    _call(id, text);
    malloc.free(text);
    return done.future;
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;
}

import 'dart:async';

import 'package:flutter/services.dart';

enum SpeechStart { listening, granted, denied, unavailable }

sealed class SpeechEvent {
  const SpeechEvent();

  static SpeechEvent? parse(Object? arguments) {
    if (arguments is! Map) return null;
    final text = arguments['text'];
    final level = arguments['level'];
    return switch (arguments['type']) {
      'level' when level is num => SpeechLevel(level.toDouble().clamp(0, 1)),
      'partial' when text is String => SpeechPartial(text),
      'final' when text is String => SpeechSettled(text),
      'failed' => SpeechFailed(denied: text == 'denied'),
      'end' => const SpeechEnded(),
      _ => null,
    };
  }
}

final class SpeechPartial extends SpeechEvent {
  const SpeechPartial(this.text);

  final String text;
}

final class SpeechLevel extends SpeechEvent {
  const SpeechLevel(this.level);

  final double level;
}

final class SpeechSettled extends SpeechEvent {
  const SpeechSettled(this.text);

  final String text;
}

final class SpeechFailed extends SpeechEvent {
  const SpeechFailed({required this.denied});

  final bool denied;
}

final class SpeechEnded extends SpeechEvent {
  const SpeechEnded();
}

abstract final class Speech {
  static const _channel = MethodChannel('dev.luisnquin.upgrade/speech');

  static final _events = StreamController<SpeechEvent>.broadcast(
    onListen: () => _channel.setMethodCallHandler(_onCall),
  );

  static Stream<SpeechEvent> get events => _events.stream;

  static Future<void> _onCall(MethodCall call) async {
    if (call.method != 'event') return;
    final event = SpeechEvent.parse(call.arguments);
    if (event != null) _events.add(event);
  }

  static Future<SpeechStart> start() async {
    try {
      final answer = await _channel.invokeMethod<String>('start');
      return SpeechStart.values.asNameMap()[answer] ?? SpeechStart.unavailable;
    } on MissingPluginException {
      return SpeechStart.unavailable;
    } on PlatformException {
      return SpeechStart.unavailable;
    }
  }

  static Future<void> stop() => _quietly('stop');

  static Future<void> cancel() => _quietly('cancel');

  static Future<void> _quietly(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // ignored: a platform with no recognizer has nothing to stop.
      return;
    } on PlatformException {
      // ignored: no caller can act on it, and the row's × still resets a stuck one.
      return;
    }
  }
}

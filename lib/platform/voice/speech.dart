import 'dart:async';

import 'package:flutter/services.dart';
import 'package:upgrade/platform/channels.dart';

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
      'cut' => const SpeechCut(),
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

final class SpeechCut extends SpeechEvent {
  const SpeechCut();
}

abstract final class Speech {
  static const _channel = MethodChannel(Channels.speech);

  static final _events = StreamController<SpeechEvent>.broadcast(
    onListen: () => _channel.setMethodCallHandler(_onCall),
  );

  static Stream<SpeechEvent> get events => _events.stream;

  static Future<void> _onCall(MethodCall call) async {
    if (call.method != 'event') return;
    final event = SpeechEvent.parse(call.arguments);
    if (event != null) _events.add(event);
  }

  static Future<SpeechStart> start() => _start('start');

  static Future<SpeechStart> record() => _start('record');

  /// No recording reads as RECORDING FAILED to the caller.
  static Future<Uint8List?> finish() =>
      failSoft(() => _channel.invokeMethod<Uint8List>('finish'), null);

  static Future<void> discard() => _quietly('discard');

  static Future<SpeechStart> _start(String method) async {
    final answer = await failSoft(
      () => _channel.invokeMethod<String>(method),
      null,
    );
    return SpeechStart.values.asNameMap()[answer] ?? SpeechStart.unavailable;
  }

  static Future<void> stop() => _quietly('stop');

  static Future<void> cancel() => _quietly('cancel');

  /// No caller can act on a failure, and the row's × still resets a stuck one.
  static Future<void> _quietly(String method) =>
      failSoft(() => _channel.invokeMethod<void>(method), null);
}

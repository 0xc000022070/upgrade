import 'package:flutter/services.dart';

abstract final class StrikedShade {
  static const _channel = MethodChannel('dev.luisnquin.striked/shade');

  static Future<void> createChannel({
    required String id,
    required String name,
    List<String> retired = const [],
  }) => _channel.invokeMethod<void>('channel', {
    'id': id,
    'name': name,
    'retired': retired,
  });

  static Future<void> show({
    required int id,
    required String channelId,
    required String title,
    required String body,
    required String payload,
    required String ask,
  }) => _channel.invokeMethod<void>('show', {
    'id': id,
    'channel': channelId,
    'title': title,
    'body': body,
    'payload': payload,
    'ask': ask,
  });

  static Future<void> cancel(int id) =>
      _channel.invokeMethod<void>('cancel', {'id': id});

  static Future<bool> dndAccess() async =>
      await _channel.invokeMethod<bool>('dndAccess') ?? false;

  static Future<void> askDndAccess() =>
      _channel.invokeMethod<void>('askDndAccess');
}

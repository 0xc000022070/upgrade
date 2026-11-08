import 'package:flutter/services.dart';
import 'package:upgrade/platform/channels.dart';

abstract final class BrowserProxy {
  static const _calls = MethodChannel(Channels.browser);

  static Future<void> set(int port) =>
      _calls.invokeMethod<void>('proxy', {'port': port});

  static Future<void> clear() => _calls.invokeMethod<void>('proxy');
}

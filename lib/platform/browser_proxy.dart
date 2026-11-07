import 'package:flutter/services.dart';

abstract final class BrowserProxy {
  static const _calls = MethodChannel('dev.luisnquin.upgrade/browser');

  static Future<void> set(int port) =>
      _calls.invokeMethod<void>('proxy', {'port': port});

  static Future<void> clear() => _calls.invokeMethod<void>('proxy');
}

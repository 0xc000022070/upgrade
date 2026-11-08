import 'package:flutter/services.dart';

import 'package:upgrade/platform/bundle_cipher.dart';
import 'package:upgrade/platform/channels.dart';

/// A platform without the picker — the desktop loop, the test harness — is a
/// [BundleException] of [BundleFault.noPicker].
abstract final class Documents {
  static const _channel = MethodChannel(Channels.device);

  static Future<bool> save({
    required String name,
    required Uint8List bytes,
  }) async {
    try {
      final saved = await _channel.invokeMethod<bool>('saveDocument', {
        'name': name,
        'mime': 'application/octet-stream',
        'bytes': bytes,
      });
      return saved ?? false;
    } on MissingPluginException {
      throw const BundleException(BundleFault.noPicker);
    } on PlatformException {
      throw const BundleException(BundleFault.noPicker);
    }
  }

  static Future<Uint8List?> open() async {
    try {
      return await _channel.invokeMethod<Uint8List>('openDocument');
    } on MissingPluginException {
      throw const BundleException(BundleFault.noPicker);
    } on PlatformException {
      throw const BundleException(BundleFault.noPicker);
    }
  }
}

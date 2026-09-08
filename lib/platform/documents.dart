import 'package:flutter/services.dart';

import 'bundle_cipher.dart';

/// The system's document picker, on the device channel: the app never decides
/// where a bundle lives. Both calls raise Android's own picker and come back
/// with what the user did there. A platform without the picker — the desktop
/// loop, the test harness — is a [BundleException] of [BundleFault.noPicker],
/// which the panel reads as `NO PICKER`.
abstract final class Documents {
  static const _channel = MethodChannel('dev.luisnquin.spectacle/device');

  /// True once the bytes are under the name the user chose, false when the
  /// picker was dismissed.
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

  /// The bytes of the file the user chose, or null when the picker was
  /// dismissed.
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

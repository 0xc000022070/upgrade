import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An [EventChannel] with no handler reports the miss through
/// [FlutterError.onError] rather than through the stream, so any test that
/// mounts the static background has to answer `listen` or it fails on an
/// exception the app itself never sees. Answering it is enough: the driver
/// starts from "not throttled" and these tests never change that.
void stubDeviceChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.luisnquin.hotline/device'),
    (call) async => call.method == 'model' ? 'test device' : null,
  );

  messenger.setMockMessageHandler(
    'dev.luisnquin.hotline/device/throttle',
    (message) async => codec.encodeSuccessEnvelope(null),
  );
}

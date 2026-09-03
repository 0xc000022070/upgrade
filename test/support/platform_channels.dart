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

/// The link icon reads the clipboard before it does anything else, so every
/// test of it has to say what is on the clipboard — including "nothing", which
/// is the branch that flips the field into URL mode.
void stubClipboard(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method != 'Clipboard.getData') return null;
        return text == null ? null : <String, dynamic>{'text': text};
      });
}

/// `AlertsHost` reconciles the foreground service the moment it
/// mounts, so any test that mounts it answers the plugin's channel. `false` is
/// "no service running", which makes both `start` and `stop` no-ops in a test
/// process that has no Android to start one on.
void stubForegroundTask() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('flutter_foreground_task/methods'),
        (call) async => switch (call.method) {
          'isRunningService' => false,
          _ => null,
        },
      );
}

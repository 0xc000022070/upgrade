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
    const MethodChannel('dev.luisnquin.spectacle/device'),
    (call) async => call.method == 'model' ? 'test device' : null,
  );

  messenger.setMockMessageHandler(
    'dev.luisnquin.spectacle/device/throttle',
    (message) async => codec.encodeSuccessEnvelope(null),
  );
}

/// The link icon reads the clipboard before it does anything else, so every
/// test of it has to say what is on the clipboard — including "nothing", which
/// is the branch that raises the line empty.
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

/// A tap on a painted URL hands it to the platform. Nothing in a test process
/// can open a browser, so the channel answers and the returned list records
/// what it was asked to open. [takes] is what the device says it did with the
/// URL: false is a phone with nothing registered for the scheme.
List<String> stubUrlLauncher({bool takes = true}) {
  final opened = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          final arguments = call.arguments as Map<Object?, Object?>?;
          switch (call.method) {
            case 'canLaunch':
              return true;
            case 'launch':
              opened.add(arguments!['url']! as String);
              return takes;
          }
          return null;
        },
      );
  return opened;
}

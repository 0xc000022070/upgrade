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

/// The other direction: what the app *wrote* to the clipboard. A copy leaves
/// nothing on the screen to assert on, so the claim is the text the platform
/// was handed. The returned list grows with every write, newest last.
List<String> recordClipboardWrites() {
  final written = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          written.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
  return written;
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

/// What the app asked the IME for. Showing and hiding a keyboard leaves nothing
/// on screen a test process can see — there is no keyboard in one — so the
/// claim is the call. The returned list grows with every one, newest last.
List<String> recordTextInput() {
  final calls = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.textInput, (call) async {
        calls.add(call.method);
        return null;
      });
  return calls;
}

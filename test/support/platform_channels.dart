import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An [EventChannel] with no handler reports the miss through [FlutterError.onError]
/// rather than through the stream, so any test that mounts the static background has to
/// answer `listen`. The document picker is on the same channel; [picker] false is a
/// platform with none, and both its calls are then missing.
void stubDeviceChannels({
  Uint8List? document,
  void Function(String name, Uint8List bytes)? onSave,
  bool picker = true,
}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.luisnquin.striked/device'),
    (call) async {
      switch (call.method) {
        case 'model':
          return 'test device';
        case 'saveDocument':
          if (!picker) throw MissingPluginException();
          final args = call.arguments as Map;
          onSave?.call(args['name'] as String, args['bytes'] as Uint8List);
          return onSave != null;
        case 'openDocument':
          if (!picker) throw MissingPluginException();
          return document;
        default:
          return null;
      }
    },
  );

  messenger.setMockMessageHandler(
    'dev.luisnquin.striked/device/throttle',
    (message) async => codec.encodeSuccessEnvelope(null),
  );

  // Answering `listen` is enough: nothing is replayed on subscribe.
  messenger.setMockMessageHandler(
    'dev.luisnquin.striked/device/network',
    (message) async => codec.encodeSuccessEnvelope(null),
  );
}

Future<void> pushNetwork(bool up) => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .handlePlatformMessage(
      'dev.luisnquin.striked/device/network',
      const StandardMethodCodec().encodeSuccessEnvelope(up),
      (_) {},
    );

/// The link icon reads the clipboard before it does anything else, including "nothing",
/// which is the branch that raises the line empty.
void stubClipboard(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method != 'Clipboard.getData') return null;
        return text == null ? null : <String, dynamic>{'text': text};
      });
}

/// A copy leaves nothing on the screen to assert on, so the claim is the text the
/// platform was handed.
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

/// `false` is "no service running", which makes both `start` and `stop` no-ops in a test
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

/// Nothing in a test process can open a browser. [takes] is what the device says it did
/// with the URL: false is a phone with nothing registered for the scheme.
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

/// Showing and hiding a keyboard leaves nothing on screen a test process can see.
List<String> recordTextInput() {
  final calls = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.textInput, (call) async {
        calls.add(call.method);
        return null;
      });
  return calls;
}

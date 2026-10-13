import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade/application/drops/clips.dart';
import 'package:upgrade/features/tasks/image_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late Map<Object?, Object?> asked;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('upgrade-attachments');
    asked = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    final source = File(p.join(support.path, 'camera-roll.jpg'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async {
        asked = call.arguments as Map<Object?, Object?>;
        return source.path;
      },
    );
    await ImageAttachments.init();
  });

  tearDown(() => support.deleteSync(recursive: true));

  test('a picked image is asked for at the size a host is sent', () async {
    final relative = await ImageAttachments.pick();

    expect(asked['maxWidth'], photoAttachEdge);
    expect(asked['maxHeight'], photoAttachEdge);
    expect(relative, isNotNull);
    expect(File(ImageAttachments.absolute(relative!)!).existsSync(), isTrue);
  });
}

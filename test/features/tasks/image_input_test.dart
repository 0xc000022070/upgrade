import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:striked/application/drops/clips.dart';
import 'package:striked/features/photos/photo_cut.dart';
import 'package:striked/features/screen/screen_preview.dart';
import 'package:striked/features/tasks/image_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late Map<Object?, Object?> asked;
  late Uint8List photo;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('striked-attachments');
    asked = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    photo = encodePng(
      PreviewFrame(width: 4, height: 3, rgb: Uint8List(4 * 3 * 3)),
    );
    final source = File(p.join(support.path, 'camera-roll.png'))
      ..writeAsBytesSync(photo);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async {
        asked = call.arguments as Map<Object?, Object?>;
        return [source.path, source.path];
      },
    );
    await ImageAttachments.init();
  });

  tearDown(() => support.deleteSync(recursive: true));

  PhotoReview keeping(List<Rect?> keeps) =>
      (paths) async => [
        for (var i = 0; i < keeps.length; i++) (path: paths[i], keep: keeps[i]),
      ];

  test('every picked photo is asked for at the size a host is sent', () async {
    final stored = await ImageAttachments.pick(keeping([null, null]));

    expect(asked['maxWidth'], photoAttachEdge);
    expect(asked['maxHeight'], photoAttachEdge);
    expect(stored, hasLength(2));
    for (final relative in stored) {
      expect(
        File(ImageAttachments.absolute(relative)!).readAsBytesSync(),
        photo,
      );
    }
  });

  test('a cropped photo keeps only the part inside the box', () async {
    final stored = await ImageAttachments.pick(
      keeping([const Rect.fromLTRB(0.25, 0, 0.75, 1)]),
    );

    expect(stored, hasLength(1));
    expect(p.extension(stored.single), '.png');
    final codec = await instantiateImageCodec(
      File(ImageAttachments.absolute(stored.single)!).readAsBytesSync(),
    );
    final image = (await codec.getNextFrame()).image;
    expect((image.width, image.height), (2, 3));
  });

  test('backing out of the review attaches nothing', () async {
    final stored = await ImageAttachments.pick((_) async => null);

    expect(stored, isEmpty);
    expect(Directory(p.join(support.path, 'attachments')).listSync(), isEmpty);
  });
}

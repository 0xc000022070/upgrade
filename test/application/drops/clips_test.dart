import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/drops/clips.dart';
import 'package:striked/features/screen/screen_preview.dart';

Uint8List png(int width, int height) => encodePng(
  PreviewFrame(
    width: width,
    height: height,
    rgb: Uint8List(width * height * 3),
  ),
);

void main() {
  late Directory directory;
  late ClipStore clips;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('striked-clips-test');
    clips = ClipStore(directory);
  });

  tearDown(() => directory.delete(recursive: true));

  test('a PNG reads its own size off the header', () {
    expect(pngSize(png(40, 24)), (width: 40, height: 24));
    expect(pngSize(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test(
    'an added clip is a file in the directory with its size known',
    () async {
      final clip = await clips.add(png(40, 24), source: ClipSource.screen);
      expect(clip.file.existsSync(), isTrue);
      expect(clip.file.parent.path, directory.path);
      expect(clip.sizeLabel, '40×24');
      expect(clips.count, 1);
      expect(clips.totalBytes, clip.bytes);
    },
  );

  test('newest first, and the oldest goes once the tray is full', () async {
    final first = await clips.add(png(8, 8), source: ClipSource.screen);
    for (var i = 0; i < ClipStore.maxClips; i++) {
      await clips.add(png(8, 8), source: ClipSource.photo);
    }
    expect(clips.count, ClipStore.maxClips);
    expect(clips.clips.first.source, ClipSource.photo);
    expect(clips.clips.map((clip) => clip.id), isNot(contains(first.id)));
    expect(first.file.existsSync(), isFalse);
  });

  test(
    'removing a clip takes its file with it and tells the listeners',
    () async {
      final clip = await clips.add(png(8, 8), source: ClipSource.screen);
      var told = 0;
      clips.addListener(() => told++);
      await clips.remove(clip);
      expect(clips.count, 0);
      expect(clip.file.existsSync(), isFalse);
      expect(told, 1);
    },
  );
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/screen/screen_preview.dart';
import 'package:dazzle/platform/vnc/framebuffer.dart';

Framebuffer _split(int width, int height) {
  final framebuffer = Framebuffer(width, height);
  // Left half red, right half blue: an average over any box inside one half is
  // that half's colour, so a downscale that reads the wrong pixels shows up as
  // a colour and not as a rounding difference.
  framebuffer.fill(0, 0, width ~/ 2, height, 0, 0, 0xFF);
  framebuffer.fill(width ~/ 2, 0, width - width ~/ 2, height, 0xFF, 0, 0);
  return framebuffer;
}

void main() {
  late Directory root;
  late ScreenPreviews previews;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dazzle-previews');
    previews = ScreenPreviews(Directory('${root.path}/screens'));
    addTearDown(previews.dispose);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a frame is downsampled to 320 wide and read back', () async {
    await previews.write('host-1', _split(1920, 1080));

    final stored = previews.read('host-1');
    expect(stored, isNotNull);
    expect(stored!.width, 320);
    expect(stored.height, 180);
    expect(stored.file.path, endsWith('screens/host-1.png'));
    expect(stored.bytes.sublist(0, 8), [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);
  });

  test('area averaging keeps each half its own colour', () {
    final frame = downsampleFrame(_split(1920, 1080));

    expect(frame.width, 320);
    expect(frame.height, 180);
    // First and last pixel of the top row, as rgb triples.
    expect(frame.rgb.sublist(0, 3), [0xFF, 0, 0]);
    expect(frame.rgb.sublist((frame.width - 1) * 3, frame.width * 3), [
      0,
      0,
      0xFF,
    ]);
  });

  test('a frame narrower than the target is stored as it is', () {
    final frame = downsampleFrame(_split(240, 180));

    expect(frame.width, 240);
    expect(frame.height, 180);
  });

  test('a host with no frame reads back as nothing', () {
    expect(previews.read('host-1'), isNull);
  });

  test('delete removes the file', () async {
    await previews.write('host-1', _split(640, 360));
    expect(previews.read('host-1'), isNotNull);

    await previews.delete('host-1');

    expect(previews.read('host-1'), isNull);
    expect(previews.fileFor('host-1').existsSync(), isFalse);
    // Deleting a host that never had one is not an error.
    await previews.delete('host-2');
  });

  test('a write and a delete both name the host they touched', () async {
    final seen = <String>[];
    final subscription = previews.changes.listen(seen.add);
    addTearDown(subscription.cancel);

    await previews.write('host-1', _split(640, 360));
    await previews.delete('host-1');
    await pumpEventQueue();

    expect(seen, ['host-1', 'host-1']);
  });

  test('a written frame replaces the one before it in place', () async {
    await previews.write('host-1', _split(1920, 1080));
    await previews.write('host-1', _split(800, 800));

    final stored = previews.read('host-1');
    expect(stored!.width, 320);
    expect(stored.height, 320);
    expect(previews.directory.listSync(), hasLength(1));
  });
}

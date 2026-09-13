/// The one line the breadcrumb shows after a crop.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/clips.dart';
import 'package:dazzle/features/screen/crop_notice.dart';
import 'package:dazzle/features/screen/framebuffer_view.dart';
import 'package:dazzle/features/screen/screen_preview.dart';

void main() {
  test('HELD carries the clip size, SAVED the pixel size', () async {
    final directory = Directory.systemTemp.createTempSync('dazzle-notice');
    addTearDown(() => directory.delete(recursive: true));
    final clips = ClipStore(directory);
    final clip = await clips.add(
      encodePng(PreviewFrame(width: 8, height: 8, rgb: Uint8List(8 * 8 * 3))),
      source: ClipSource.screen,
    );
    expect(heldNotice(clip), 'HELD · ${clip.sizeLabel}');
    expect(savedNotice(240, 120), 'SAVED · 240×120');
  });

  test('a failure names the verb and what went wrong', () {
    expect(
      cropFailedNotice(CropTarget.save, 'gallery access denied'),
      'SAVE FAILED · gallery access denied',
    );
    expect(
      cropFailedNotice(CropTarget.hold, 'disk full'),
      'HOLD FAILED · disk full',
    );
  });
}

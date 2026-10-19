import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:striked/features/photos/photo_cut.dart';
import 'package:striked/features/photos/photo_review.dart';
import 'package:striked/features/screen/screen_preview.dart';

import '../../support/themed_app.dart';

void main() {
  const box = Rect.fromLTRB(100, 100, 300, 300);
  const bounds = Rect.fromLTRB(0, 0, 400, 400);

  test('a corner takes its two sides, the inside takes the body', () {
    expect(gripAt(box, const Offset(105, 295), 24), (
      left: true,
      top: false,
      right: false,
      bottom: true,
    ));
    expect(gripAt(box, const Offset(200, 200), 24), trimBody);
    expect(gripAt(box, const Offset(20, 20), 24), isNull);
  });

  test('a side stops short of the one facing it and at the photo edge', () {
    const left = (left: true, top: false, right: false, bottom: false);
    expect(dragTrim(box, left, const Offset(500, 0), bounds, 48).left, 252);
    expect(dragTrim(box, left, const Offset(-500, 0), bounds, 48).left, 0);
  });

  test('the body moves whole and stays on the photo', () {
    expect(
      dragTrim(box, trimBody, const Offset(500, -30), bounds, 48),
      const Rect.fromLTRB(200, 70, 400, 270),
    );
  });

  group('review', () {
    late Directory dir;
    late List<String> paths;
    List<ReviewedPhoto>? result;
    var returned = false;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('striked-review');
      paths = [
        for (final name in ['a', 'b'])
          (File(p.join(dir.path, '$name.png'))..writeAsBytesSync(
                encodePng(
                  PreviewFrame(
                    width: 40,
                    height: 30,
                    rgb: Uint8List(40 * 30 * 3),
                  ),
                ),
              ))
              .path,
      ];
      result = null;
      returned = false;
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Builder(
            builder: (context) => GestureDetector(
              onTap: () async {
                result = await reviewPhotos(context, paths, verb: 'SEND');
                returned = true;
              },
              child: const Center(child: Text('OPEN')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      final framed = find.descendant(
        of: find.byKey(const ValueKey('review-photo-0')),
        matching: find.byType(Image),
      );
      for (var i = 0; i < 100 && framed.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(framed, findsOneWidget);
    }

    testWidgets('a removed photo is not sent and the rest are, uncut', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('SEND 2'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('review-remove')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('review-send')));
      await tester.pumpAndSettle();

      expect(result, [(path: paths[1], keep: null)]);
    });

    testWidgets('a crop is kept as fractions of the photo', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('review-crop')));
      await tester.pump();
      final photo = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('review-photo-0')),
          matching: find.byType(Image),
        ),
      );
      await tester.dragFrom(
        photo.topLeft + const Offset(2, 2),
        Offset(photo.width / 2, 0),
      );
      await tester.tap(find.byKey(const ValueKey('crop-done')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('review-send')));
      await tester.pumpAndSettle();

      final keep = result!.first.keep!;
      expect(keep.left, moreOrLessEquals(0.5, epsilon: 0.05));
      expect((keep.top, keep.right, keep.bottom), (0.0, 1.0, 1.0));
      expect(result![1].keep, isNull);
    });

    testWidgets('back while cropping leaves the crop, not the review', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('review-crop')));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(returned, isFalse);
      expect(find.byKey(const ValueKey('review-crop')), findsOneWidget);
    });
  });
}

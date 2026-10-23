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

  test('a mark is burned in at its place and the photo is not cut', () async {
    final source = encodePng(
      PreviewFrame(width: 400, height: 400, rgb: Uint8List(400 * 400 * 3)),
    );
    final out = await cutImage(source, null, const [
      (shape: MarkShape.box, from: Offset(0.2, 0.2), to: Offset(0.8, 0.8)),
    ]);

    final image = await decodeImageFromList(out!);
    final pixels = (await image.toByteData())!;
    int red(int x, int y) => pixels.getUint8((y * 400 + x) * 4);
    expect((image.width, image.height), (400, 400));
    expect(red(80, 200), 0xB7);
    expect(red(200, 200), 0);
    expect(await cutImage(source, null, const []), isNull);
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

      expect(result, [
        (path: paths[1], keep: null, marks: const <PhotoMark>[]),
      ]);
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

    Rect shownPhoto(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('review-photo-0')),
        matching: find.byType(Image),
      ),
    );

    testWidgets('marks are drawn by drag, undone from the last, and sent', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('review-mark')));
      await tester.pump();
      final photo = shownPhoto(tester);
      await tester.tap(find.byKey(const ValueKey('mark-arrow')));
      await tester.pump();
      await tester.dragFrom(photo.center, Offset(photo.width / 4, 0));
      await tester.pump();
      await tester.dragFrom(
        photo.topLeft + const Offset(4, 4),
        const Offset(4, 0),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mark-ring')));
      await tester.pump();
      await tester.dragFrom(photo.topLeft, photo.size.bottomRight(Offset.zero));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mark-undo')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mark-done')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('review-send')));
      await tester.pumpAndSettle();

      final mark = result!.first.marks.single;
      expect(mark.shape, MarkShape.arrow);
      expect(mark.from.dx, moreOrLessEquals(0.5, epsilon: 0.05));
      expect(mark.to.dx, moreOrLessEquals(0.75, epsilon: 0.05));
      expect(result!.first.keep, isNull);
      expect(result![1].marks, isEmpty);
    });

    testWidgets('back while marking forgets what this round drew', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('review-mark')));
      await tester.pump();
      final photo = shownPhoto(tester);
      await tester.dragFrom(photo.topLeft, photo.size.bottomRight(Offset.zero));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-send')));
      await tester.pumpAndSettle();

      expect(result!.first.marks, isEmpty);
    });

    testWidgets('a loupe follows a held crop corner and goes on lift', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('review-crop')));
      await tester.pump();
      final photo = shownPhoto(tester);
      final loupe = find.byKey(const ValueKey('review-loupe'));

      final gesture = await tester.startGesture(
        photo.bottomRight - const Offset(2, 2),
      );
      await gesture.moveBy(const Offset(-40, -40));
      await tester.pump();
      expect(loupe, findsOneWidget);
      final focus =
          tester
              .widget<RawMagnifier>(find.byType(RawMagnifier))
              .focalPointOffset +
          tester.getCenter(loupe);
      expect(focus.dx, moreOrLessEquals(photo.right - 40, epsilon: 2));
      expect(focus.dy, moreOrLessEquals(photo.bottom - 40, epsilon: 2));

      await gesture.up();
      await tester.pump();
      expect(loupe, findsNothing);
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

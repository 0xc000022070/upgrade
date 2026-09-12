/// A path is identified by its end, so the line gives up its directories from
/// the left rather than ellipsizing its name away.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/design/components/path_line.dart';
import 'package:spectacle/design/components/signal_text.dart';
import 'package:spectacle/design/typography.dart';

Future<String> pumpPath(
  WidgetTester tester,
  String path, {
  required double width,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: PathLine(path, style: SpectacleText.rowTitle),
        ),
      ),
    ),
  );
  return tester.widget<SignalText>(find.byType(SignalText)).data;
}

void main() {
  const deep = 'android/app/src/main/kotlin/dev/luisnquin/MainActivity.kt';

  testWidgets('a path that fits is drawn whole', (tester) async {
    expect(await pumpPath(tester, deep, width: 4000), deep);
  });

  testWidgets('a path that does not fit gives up leading directories', (
    tester,
  ) async {
    final line = await pumpPath(tester, deep, width: 500);
    expect(line, startsWith('…/'));
    expect(line, endsWith('/MainActivity.kt'));
    // Only what it had to: the loop stops at the first line that fits, so a
    // width with room to spare keeps more of the path than the floor does.
    expect(line.length, greaterThan('…/MainActivity.kt'.length));
  });

  testWidgets('the name is the floor and it keeps its mark', (tester) async {
    // Narrower than any segment: there is nothing left to give up, so the line
    // is the name with the `…` still saying directories were dropped, and the
    // ellipsis in the text does the rest.
    expect(await pumpPath(tester, deep, width: 20), '…/MainActivity.kt');
  });

  testWidgets('a bare name has nothing to give up', (tester) async {
    expect(await pumpPath(tester, 'README.md', width: 20), 'README.md');
  });
}

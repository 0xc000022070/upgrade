import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/components/path_line.dart';
import 'package:upgrade/design/components/signal_text.dart';
import 'package:upgrade/design/typography.dart';

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
          child: PathLine(path, style: UpgradeText.rowTitle),
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
    expect(line.length, greaterThan('…/MainActivity.kt'.length));
  });

  testWidgets('the name is the floor and it keeps its mark', (tester) async {
    expect(await pumpPath(tester, deep, width: 20), '…/MainActivity.kt');
  });

  testWidgets('a bare name has nothing to give up', (tester) async {
    expect(await pumpPath(tester, 'README.md', width: 20), 'README.md');
  });
}

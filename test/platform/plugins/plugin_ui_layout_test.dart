import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/ui.dart';

import '../../support/themed_app.dart';

Map<String, Object?> node(
  String kind,
  String key, {
  Map<String, Object?> props = const {},
  List<Map<String, Object?>> children = const [],
}) => {
  'kind': kind,
  'props': {'key': key, ...props},
  'children': children,
};

void main() {
  PluginUiNode parse(
    Map<String, Object?> source, {
    bool card = false,
    bool allowAwake = false,
  }) => PluginUiNode.parse(
    source,
    allowCanvas: false,
    card: card,
    allowAwake: allowAwake,
    pages: const {'main'},
  );

  test('fill, awake and opens are refused where they do not belong', () {
    final column = node('column', 'body');
    for (final source in [
      node('page', 'p', props: {'fill': true}),
      node(
        'page',
        'p',
        props: {'fill': true},
        children: [column, node('text', 't')],
      ),
      node('page', 'p', props: {'awake': true}, children: [column]),
      node('column', 'c', props: {'awake': false}),
      node('button', 'b', props: {'opens': 'elsewhere'}),
      node('text', 't', props: {'opens': 'main'}),
    ]) {
      expect(() => parse(source), throwsA(isA<PluginException>()));
    }
    expect(
      parse(
        node(
          'page',
          'p',
          props: {'fill': true, 'awake': true},
          children: [column, node('footer', 'f')],
        ),
        allowAwake: true,
      ).props['awake'],
      isTrue,
    );
    expect(
      parse(
        node(
          'panel',
          'card',
          children: [
            node('button', 'b', props: {'opens': 'main'}),
          ],
        ),
        card: true,
      ).children.single.props['opens'],
      'main',
    );
  });

  testWidgets('a filling page hands its height to sideways columns', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    final opened = <String>[];
    Map<String, Object?> lane(int index) => node(
      'column',
      'lane$index',
      props: {'width': 200, 'align': 'stretch'},
      children: [
        node('text', 'name$index', props: {'text': 'LANE $index'}),
        node(
          'list',
          'cards$index',
          props: {'flex': 1},
          children: [
            node(
              'box',
              'card$index',
              props: {
                'onPress': 'open',
                'args': {'id': index},
              },
              children: [
                node(
                  'text',
                  'body$index',
                  props: {'text': 'line\n' * 10, 'lines': 3},
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final view = parse(
      node(
        'page',
        'page',
        props: {'fill': true, 'title': 'BOARD'},
        children: [
          node(
            'column',
            'body',
            children: [
              node('button', 'go', props: {'text': 'GO', 'opens': 'main'}),
              node(
                'list',
                'board',
                props: {'direction': 'horizontal', 'flex': 1},
                children: [for (var i = 0; i < 4; i++) lane(i)],
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: PluginUi(
            node: view,
            values: {},
            onEvent: events.add,
            onOpen: opened.add,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final screen = tester.getSize(find.byType(PluginUi));
    final board = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(board.bottom, closeTo(screen.height, 48));
    expect(board.height, greaterThan(screen.height / 2));
    expect(find.text('LANE 3'), findsNothing);
    final body = tester.widget<Text>(find.text('line\n' * 10).first);
    expect(body.maxLines, 3);
    expect(body.overflow, TextOverflow.ellipsis);

    await tester.tap(find.text('line\n' * 10).first);
    expect(events.single['id'], 'open');
    expect(events.single['args'], {'id': 0});
    await tester.tap(find.text('GO'));
    expect(opened, ['main']);

    await tester.drag(find.text('LANE 0'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('LANE 3'), findsOneWidget);
  });

  testWidgets('a filling page too short for its board scrolls, not overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final view = parse(
      node(
        'page',
        'page',
        props: {'fill': true, 'title': 'BOARD'},
        children: [
          node(
            'column',
            'body',
            props: {'gap': 8, 'align': 'stretch'},
            children: [
              for (var i = 0; i < 6; i++)
                node('box', 'tall$i', props: {'height': 80}),
              node(
                'list',
                'board',
                props: {'direction': 'horizontal', 'flex': 1},
                children: [
                  node('text', 'lane', props: {'text': 'LANE'}),
                ],
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: PluginUi(node: view, values: {}, onEvent: (_) {}),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final board = find.byWidgetPredicate(
      (widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    expect(tester.getSize(board).height, 240);
    await tester.drag(
      find.byKey(const ValueKey('tall0')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(board).bottom, lessThanOrEqualTo(600));
    expect(find.text('LANE'), findsOneWidget);
  });

  testWidgets('a live input sends as it is typed and keeps what came after', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    Widget build(String value, {bool busy = false}) => MaterialApp(
      theme: testTheme,
      home: Scaffold(
        body: PluginUi(
          node: parse(
            node(
              'input',
              'search',
              props: {'value': value, 'onChange': 'search', 'live': true},
            ),
          ),
          values: {},
          busy: busy,
          onEvent: events.add,
        ),
      ),
    );
    await tester.pumpWidget(build(''));
    await tester.enterText(find.byType(TextField), 'par');
    await tester.pump(const Duration(milliseconds: 100));
    expect(events, isEmpty);
    await tester.pumpWidget(build('', busy: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(events, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.pumpWidget(build(''));
    await tester.pump(const Duration(milliseconds: 400));
    expect(events.single['value'], 'par');
    await tester.enterText(find.byType(TextField), 'parser');
    await tester.pumpWidget(build('par'));
    expect(find.text('parser'), findsOneWidget);
    await tester.pumpWidget(build(''));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('parser'), findsNothing);
    expect(events, hasLength(1));
    expect(
      () => parse(node('text', 't', props: {'live': true})),
      throwsA(isA<PluginException>()),
    );
  });
}

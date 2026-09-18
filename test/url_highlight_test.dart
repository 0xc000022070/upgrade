import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/urls.dart';
import 'package:dazzle/design/tokens.dart';
import 'package:dazzle/features/tasks/url_highlight_controller.dart';

import 'support/themed_app.dart';

void main() {
  late BuildContext ctx;

  /// [buildTextSpan] reaches `context.tokens`, so the context it is handed has to be a live
  /// one rather than an element that was never mounted.
  Future<void> mountContext(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  List<(String, bool)> render(String text) {
    final controller = UrlHighlightController(text: text);
    final span = controller.buildTextSpan(
      context: ctx,
      style: TextStyle(color: ctx.tokens.textPrimary),
      withComposing: false,
    );
    final out = <(String, bool)>[];
    span.visitChildren((child) {
      final piece = child as TextSpan;
      if (piece.text == null) return true;
      out.add((piece.text!, piece.style?.backgroundColor != null));
      return true;
    });
    // `visitChildren` on a childless span visits the span itself.
    if (out.isEmpty && span.text != null) out.add((span.text!, false));
    return out;
  }

  testWidgets('a bare sentence is one unmarked span', (tester) async {
    await mountContext(tester);
    expect(render('llamar al dentista'), [('llamar al dentista', false)]);
  });

  testWidgets('a URL mid-sentence is marked and nothing around it is', (
    tester,
  ) async {
    await mountContext(tester);
    expect(render('mirar https://min.io/docs manana'), [
      ('mirar ', false),
      ('https://min.io/docs', true),
      (' manana', false),
    ]);
  });

  testWidgets(
    'the marked run is the whole whitespace token, trailing dot and all',
    (tester) async {
      await mountContext(tester);
      const text = 'trailing https://min.io.';
      expect(
        render(text).where((span) => span.$2).single.$1,
        'https://min.io.',
      );
      expect(urlTokens(text).single.url, 'https://min.io.');
    },
  );

  testWidgets('a bracketed URL is neither painted nor opened', (tester) async {
    await mountContext(tester);
    const text = 'ver (https://min.io/docs)';
    expect(render(text).any((span) => span.$2), isFalse);
    expect(urlTokens(text), isEmpty);
  });

  testWidgets('a schemeless host stays prose', (tester) async {
    await mountContext(tester);
    expect(render('revisar pgbouncer.conf'), [
      ('revisar pgbouncer.conf', false),
    ]);
    expect(urlTokens('revisar pgbouncer.conf'), isEmpty);
  });

  testWidgets('two URLs get two marks', (tester) async {
    await mountContext(tester);
    final spans = render('https://min.io y https://garagehq.deuxfleurs.fr/');
    expect(spans.where((span) => span.$2).map((span) => span.$1), [
      'https://min.io',
      'https://garagehq.deuxfleurs.fr/',
    ]);
  });

  testWidgets('the marked ink and ground are the link tokens, with no '
      'underline', (tester) async {
    await mountContext(tester);
    final controller = UrlHighlightController(text: 'a https://min.io b');
    final span = controller.buildTextSpan(
      context: ctx,
      style: TextStyle(color: ctx.tokens.textPrimary),
      withComposing: false,
    );
    final marked = (span.children!.whereType<TextSpan>().toList())[1];
    expect(marked.style!.color, ctx.tokens.textMuted);
    expect(marked.style!.backgroundColor, ctx.tokens.surfaceSecondary);
    expect(marked.style!.decoration, TextDecoration.none);
  });

  testWidgets('what is painted is what a tap opens, token for token', (
    tester,
  ) async {
    await mountContext(tester);
    const lines = [
      'https://min.io',
      'nada aqui',
      'mirar https://min.io/docs y https://example.com/a?b=c#d',
      'mailto:alguien@example.com no es un link',
      'trailing https://min.io.',
    ];
    for (final line in lines) {
      final painted = render(line)
          .where((span) => span.$2)
          .map((span) => span.$1)
          .toList();
      final opened = urlTokens(line)
          .map((token) => line.substring(token.start, token.end))
          .toList();
      expect(painted, opened, reason: line);
    }
  });

  testWidgets('the value itself is never rewritten', (tester) async {
    await mountContext(tester);
    final controller = UrlHighlightController(text: 'a https://min.io b');
    controller.buildTextSpan(
      context: ctx,
      style: const TextStyle(),
      withComposing: true,
    );
    expect(controller.text, 'a https://min.io b');
  });
}

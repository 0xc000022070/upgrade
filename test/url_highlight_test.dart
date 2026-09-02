import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/features/tasks/link_input.dart';
import 'package:hotline/features/tasks/url_highlight_controller.dart';

/// SPEC.md §39.15. The highlight is a promise about what `_submit` will do, so
/// the assertion that matters is that the painted ranges and [extractUrls]
/// never disagree.
void main() {
  /// The spans a real field would get, flattened to (text, marked) pairs.
  List<(String, bool)> render(String text) {
    final controller = UrlHighlightController(text: text);
    final span = controller.buildTextSpan(
      context: _FakeContext(),
      style: const TextStyle(color: HotlineColors.textPrimary),
      withComposing: false,
    );
    final out = <(String, bool)>[];
    span.visitChildren((child) {
      final piece = child as TextSpan;
      if (piece.text == null) return true;
      out.add((piece.text!, piece.style?.backgroundColor != null));
      return true;
    });
    // A field with no URL in it gets one plain span, and `visitChildren` on a
    // childless span visits the span itself.
    if (out.isEmpty && span.text != null) out.add((span.text!, false));
    return out;
  }

  test('a bare sentence is one unmarked span', () {
    expect(render('llamar al dentista'), [('llamar al dentista', false)]);
  });

  test('a URL mid-sentence is marked and nothing around it is', () {
    expect(render('mirar https://min.io/docs manana'), [
      ('mirar ', false),
      ('https://min.io/docs', true),
      (' manana', false),
    ]);
  });

  test(
    'the marked run is the whole whitespace token, trailing dot and all',
    () {
      // §39.6 attaches the token as typed, so the highlight has to cover the
      // trailing dot too: a mark that stopped at `.io` would promise a link the
      // submit does not attach.
      const text = 'trailing https://min.io.';
      expect(
        render(text).where((span) => span.$2).single.$1,
        'https://min.io.',
      );
      expect(extractUrls(text), ['https://min.io.']);
    },
  );

  test('a bracketed URL is neither painted nor taken', () {
    // `(https://...)` has no authority once the bracket is part of it, so
    // `extractUrls` drops it — and the field must not claim otherwise.
    const text = 'ver (https://min.io/docs)';
    expect(render(text).any((span) => span.$2), isFalse);
    expect(extractUrls(text), isEmpty);
  });

  test('a schemeless host stays prose, exactly as extractUrls says', () {
    expect(render('revisar pgbouncer.conf'), [
      ('revisar pgbouncer.conf', false),
    ]);
    expect(extractUrls('revisar pgbouncer.conf'), isEmpty);
  });

  test('two URLs get two marks', () {
    final spans = render('https://min.io y https://garagehq.deuxfleurs.fr/');
    expect(spans.where((span) => span.$2).map((span) => span.$1), [
      'https://min.io',
      'https://garagehq.deuxfleurs.fr/',
    ]);
  });

  test(
    'the marked ink and ground are the §39.15 tokens, with no underline',
    () {
      final controller = UrlHighlightController(text: 'a https://min.io b');
      final span = controller.buildTextSpan(
        context: _FakeContext(),
        style: const TextStyle(color: HotlineColors.textPrimary),
        withComposing: false,
      );
      final marked = (span.children!.whereType<TextSpan>().toList())[1];
      expect(marked.style!.color, HotlineColors.textMuted);
      expect(marked.style!.backgroundColor, HotlineColors.surfaceSecondary);
      expect(marked.style!.decoration, TextDecoration.none);
    },
  );

  test('what is painted is what extractUrls takes, token for token', () {
    const lines = [
      'https://min.io',
      'nada aqui',
      'mirar https://min.io/docs y https://example.com/a?b=c#d',
      'mailto:alguien@example.com no es un link',
      'trailing https://min.io.',
    ];
    for (final line in lines) {
      final painted = urlTokens(line).map((token) => token.url).toList();
      expect(painted, extractUrls(line), reason: line);
    }
  });

  test('the value itself is never rewritten', () {
    final controller = UrlHighlightController(text: 'a https://min.io b');
    controller.buildTextSpan(
      context: _FakeContext(),
      style: const TextStyle(),
      withComposing: true,
    );
    expect(controller.text, 'a https://min.io b');
  });
}

/// [TextEditingController.buildTextSpan] takes a context it does not use here;
/// building a whole element tree for it would test Flutter, not the override.
class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _FakeContext extends StatelessElement {
  _FakeContext() : super(const _Nothing());
}

import 'package:upgrade_highlight/upgrade_highlight.dart';
import 'package:upgrade_highlight/languages/all.dart';
import 'package:flutter_test/flutter_test.dart';

const _samples = <String, String>{
  'bash': 'if [ -z "\$X" ]; then echo hi; fi',
  'c': '#include <stdio.h>\nint main(void) { return 0; }',
  'cpp': 'auto x = std::vector<int>{1, 2};',
  'css': 'a:hover { color: #fff; }',
  'dart': "final name = 'luis'; // one",
  'diff': '--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new',
  'dockerfile': 'FROM alpine\nRUN apk add git',
  'go': 'func main() { fmt.Println("hi", 42) }',
  'graphql': 'query { host(id: 1) { name } }',
  'http': 'GET / HTTP/1.1\nHost: x\n\n',
  'ini': '[core]\n\teditor = vim',
  'java': 'public class A { int x = 1; }',
  'javascript': 'const x = `a\${b}`;',
  'json': '{"port": 357, "on": true}',
  'kotlin': 'fun main() { val x = 1 }',
  'lua': 'local function f(x) return x + 1 end -- c',
  'makefile': 'all:\n\t\$(CC) -o x x.c',
  'markdown': '# Title\n\n```dart\nfinal x = 1;\n```\n- item',
  'nginx': 'server { listen 80; }',
  'nix': '{ pkgs, ... }: { x = "s\${y}"; }',
  'plaintext': 'just words',
  'properties': 'key = value',
  'protobuf': 'message A { int32 x = 1; }',
  'python': 'def f(x):\n    return x  # c',
  'rust': 'fn main() { let x: u32 = 5; }',
  'scala': 'val x: Int = 1',
  'scss': r'$c: #fff; a { color: $c; }',
  'shell': r'$ ls -la',
  'sql': 'select * from hosts where port = 357;',
  'typescript': 'const x: number = 1;',
  'xml': '<a href="x">t</a>',
  'yaml': 'name: upgrade # hey\nlist:\n  - true',
};

void main() {
  late Highlight engine;

  setUpAll(() => engine = highlighterWithAllLanguages());

  test('a sample is written for every grammar shipped', () {
    expect(_samples.keys.toSet(), builtinLanguages.keys.toSet());
  });

  for (final entry in _samples.entries) {
    test('${entry.key} parses its sample and hands the text back whole', () {
      final result = engine.highlight(code: entry.value, language: entry.key);
      expect(result.errorRaised, isNull);
      expect(result.illegal, isFalse);
      final spans = result.spans();
      expect(spans.map((span) => span.text).join(), entry.value);
      expect(spans, isNotEmpty);
    });
  }

  test('scopes nest, outermost first', () {
    final spans = engine
        .highlight(code: 'x = "s\${y}";', language: 'nix')
        .spans();
    expect(
      spans.map((span) => span.scopes),
      containsAll([
        ['string'],
        ['string', 'subst'],
      ]),
    );
  });

  test('a fenced block is code, not a guess at its language', () {
    final spans = engine
        .highlight(code: '```\nlet x = 1;\n```', language: 'markdown')
        .spans();
    expect(spans.single.scopes, ['code']);
  });

  test('a grammar it does not have is an error, not a silent plain', () {
    expect(
      () => engine.highlight(code: 'x', language: 'cobol'),
      throwsA(isA<Error>()),
    );
  });
}

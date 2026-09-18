import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/code/syntax.dart';

List<(String, SyntaxToken)> coloured(String line, String path) => [
  for (final span in highlight(line, languageOf(path)))
    if (span.token != SyntaxToken.plain) (span.text, span.token),
];

void main() {
  group('the language a file is read as', () {
    test('comes from the extension and from nothing else', () {
      // `func` is a keyword in one of these and a name in the other, and the path is the only
      // thing that says which.
      expect(
        coloured('func main() {', 'cmd/herdr/main.go'),
        contains(('func', SyntaxToken.keyword)),
      );
      expect(
        coloured('func main() {', 'lib/main.dart'),
        isNot(contains(('func', SyntaxToken.keyword))),
      );
    });

    test('reads a dotfile as its own name', () {
      expect(
        coloured('export PATH=/usr/bin', '.zshrc'),
        contains(('export', SyntaxToken.keyword)),
      );
    });

    test('reads the files that have no extension by their name', () {
      expect(languageOf('Dockerfile')?.name, 'dockerfile');
      expect(languageOf('build/Makefile')?.name, 'makefile');
      expect(languageOf('etc/nginx.conf')?.name, 'nginx');
    });

    test('leaves a file it does not know whole and plain', () {
      expect(languageOf('notes.xyz'), isNull);
      expect(languageOf('Program.cs'), isNull);
      expect(highlight('const port = 357;', languageOf('notes.xyz')), [
        (text: 'const port = 357;', token: SyntaxToken.plain),
      ]);
    });

    test('every language named has a grammar behind it', () {
      const files = [
        'a.dart',
        'a.js',
        'a.ts',
        'a.go',
        'a.rs',
        'a.py',
        'a.c',
        'a.cpp',
        'a.java',
        'a.kt',
        'a.scala',
        'a.sh',
        'a.yaml',
        'a.toml',
        'a.json',
        'a.sql',
        'a.nix',
        'a.lua',
        'a.md',
        'a.mk',
        'a.css',
        'a.scss',
        'a.html',
        'a.proto',
        'a.graphql',
        'a.properties',
        'a.patch',
        'a.http',
        'Dockerfile',
      ];
      for (final file in files) {
        final language = languageOf(file);
        expect(language, isNotNull, reason: file);
        // A grammar the engine does not have would come back plain whole, and a comment is the
        // one thing every grammar here colours.
        final lines = highlightLines('x = 1', language!);
        expect(lines.single.map((span) => span.text).join(), 'x = 1');
      }
    });
  });

  group('what a line is cut into', () {
    test('gives back the line it was handed, whatever it did with it', () {
      const lines = {
        'lib/main.dart': [
          "  final name = 'luis'; // the one on the key",
          '@override',
          '',
          '  Widget build(BuildContext context) => const SizedBox();',
        ],
        'pubspec.yaml': ['  version: 1.0.0+101'],
        'x.sql': ['select * from hosts where port = 357;'],
        'flake.nix': ['  x = "s\${y}";'],
      };
      for (final entry in lines.entries) {
        for (final line in entry.value) {
          final spans = highlight(line, languageOf(entry.key));
          expect(spans.map((span) => span.text).join(), line, reason: line);
        }
      }
    });

    test('a keyword and a number', () {
      expect(coloured('const port = 357;', 'lib/main.dart'), [
        ('const', SyntaxToken.keyword),
        ('357', SyntaxToken.number),
      ]);
    });

    test('a string keeps its quotes', () {
      expect(
        coloured("  final name = 'luis';", 'lib/main.dart'),
        contains(("'luis'", SyntaxToken.string)),
      );
    });

    test('a comment takes the rest of the line and nothing before it', () {
      expect(coloured('const port = 357; // the sshd', 'lib/main.dart'), [
        ('const', SyntaxToken.keyword),
        ('357', SyntaxToken.number),
        ('// the sshd', SyntaxToken.comment),
      ]);
    });

    test('a line that reads as inside a block comment is a comment whole', () {
      expect(coloured('  /// one line at a time', 'lib/main.dart'), [
        ('/// one line at a time', SyntaxToken.comment),
      ]);
      expect(coloured('   * and never across two', 'lib/main.dart'), [
        ('   * and never across two', SyntaxToken.comment),
      ]);
      // And where there are no block comments there is no continuation to read: a leading `*`
      // is multiplication.
      expect(
        coloured('   * and never across two', 'run.py'),
        isNot(contains(('   * and never across two', SyntaxToken.comment))),
      );
    });

    test('an annotation is the sigil and the one word after it', () {
      expect(
        coloured('@override', 'lib/main.dart'),
        contains(('@override', SyntaxToken.annotation)),
      );
    });

    test('a type is what the grammar says is one', () {
      expect(
        coloured('let x: u32 = 5;', 'src/main.rs'),
        contains(('u32', SyntaxToken.type)),
      );
      expect(
        coloured('PORT=357', 'deploy.sh'),
        isNot(contains(('PORT', SyntaxToken.type))),
      );
    });

    test('a key is an annotation and its value is a number', () {
      expect(coloured('  "port": 357', 'settings.json'), [
        ('"port"', SyntaxToken.annotation),
        (':', SyntaxToken.punctuation),
        ('357', SyntaxToken.number),
      ]);
    });

    test('the text inside a string interpolation is code again', () {
      expect(
        coloured('  x = "s\${y}";', 'flake.nix'),
        isNot(contains(('\${y}', SyntaxToken.string))),
      );
    });
  });

  group('what a file is cut into', () {
    const dart = '''
/* a block
   that runs on
   and closes */ final x = 1;

final y = "two";
''';

    test('one list per line, and every line whole', () {
      final lines = highlightLines(dart, languageOf('a.dart')!);
      final split = dart.split('\n');
      expect(lines.length, split.length);
      for (var i = 0; i < split.length; i++) {
        expect(lines[i].map((span) => span.text).join(), split[i]);
      }
    });

    test('a block comment is a comment to where it ends', () {
      final lines = highlightLines(dart, languageOf('a.dart')!);
      expect(lines[1].single.token, SyntaxToken.comment);
      expect(lines[2].first, (
        text: '   and closes */',
        token: SyntaxToken.comment,
      ));
      expect(lines[2], contains((text: 'final', token: SyntaxToken.keyword)));
    });

    test('an empty line is one empty plain run', () {
      final lines = highlightLines(dart, languageOf('a.dart')!);
      expect(lines[3], [(text: '', token: SyntaxToken.plain)]);
    });

    test('a long file is coloured the same on another isolate', () async {
      final inline = await highlightFile(dart, languageOf('a.dart'));
      final elsewhere = await highlightFile(
        dart,
        languageOf('a.dart'),
        inlineBytes: 0,
      );
      expect(elsewhere, inline);
    });

    test('a file with no grammar is every line plain', () async {
      final lines = await highlightFile('a\nb', null);
      expect(lines, [
        [(text: 'a', token: SyntaxToken.plain)],
        [(text: 'b', token: SyntaxToken.plain)],
      ]);
    });
  });
}

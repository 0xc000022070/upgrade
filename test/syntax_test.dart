import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/code/syntax.dart';

/// The colouring under the diff's own two colours.
///
/// Every one of these is a single line handed over on its own, because that is
/// the only thing the highlighter is ever given: a hunk is not a file, and the
/// line above a line in a hunk may not be the line above it in the checkout.

/// The runs that carry a colour, which is what the eye is being asked about.
/// The plain runs between them are the colour the whole line used to be.
List<(String, SyntaxToken)> coloured(String line, String path) => [
  for (final span in highlight(line, languageOf(path)))
    if (span.token != SyntaxToken.plain) (span.text, span.token),
];

void main() {
  group('the language a file is read as', () {
    test('comes from the extension and from nothing else', () {
      // `func` is a keyword in one of these and a name in the other, and the
      // path is the only thing that says which.
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

    test('leaves a file it does not know whole and plain', () {
      expect(languageOf('notes.xyz'), isNull);
      expect(highlight('const port = 357;', languageOf('notes.xyz')), [
        (text: 'const port = 357;', token: SyntaxToken.plain),
      ]);
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
      };
      for (final entry in lines.entries) {
        for (final line in entry.value) {
          final spans = highlight(line, languageOf(entry.key));
          expect(spans.map((span) => span.text).join(), line, reason: line);
        }
      }
    });

    test('a keyword, a number, and the punctuation around them', () {
      expect(coloured('const port = 357;', 'lib/main.dart'), [
        ('const', SyntaxToken.keyword),
        ('=', SyntaxToken.punctuation),
        ('357', SyntaxToken.number),
        (';', SyntaxToken.punctuation),
      ]);
    });

    test('a string keeps its quotes', () {
      expect(
        coloured("  final name = 'luis';", 'lib/main.dart'),
        contains(("'luis'", SyntaxToken.string)),
      );
    });

    test('a quote with no partner is a string to the end of the line', () {
      // The rest of it is in the next line of the file, which is not here.
      expect(
        coloured("  print('hello", 'lib/main.dart'),
        contains(("'hello", SyntaxToken.string)),
      );
    });

    test('a comment takes the rest of the line and nothing before it', () {
      expect(coloured('const port = 357; // the sshd', 'lib/main.dart'), [
        ('const', SyntaxToken.keyword),
        ('=', SyntaxToken.punctuation),
        ('357', SyntaxToken.number),
        (';', SyntaxToken.punctuation),
        ('// the sshd', SyntaxToken.comment),
      ]);
    });

    test('a line that reads as inside a block comment is a comment whole', () {
      // The one guess worth making: a diff shows more of a doc comment's
      // middle than of its opening line.
      expect(coloured('  /// one line at a time', 'lib/main.dart'), [
        ('/// one line at a time', SyntaxToken.comment),
      ]);
      expect(coloured('   * and never across two', 'lib/main.dart'), [
        ('   * and never across two', SyntaxToken.comment),
      ]);
      // And where there are no block comments there is no continuation to
      // read: a leading `*` is multiplication.
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

    test('a capital leads a type only where the language says so', () {
      expect(
        coloured('Widget build(BuildContext context) {', 'lib/main.dart'),
        containsAll([
          ('Widget', SyntaxToken.type),
          ('BuildContext', SyntaxToken.type),
        ]),
      );
      // A shell has no types and plenty of shouting.
      expect(
        coloured('PORT=357', 'deploy.sh'),
        isNot(contains(('PORT', SyntaxToken.type))),
      );
    });

    test('a key is a string and its value is a number', () {
      expect(coloured('  "port": 357', 'settings.json'), [
        ('"port"', SyntaxToken.string),
        (':', SyntaxToken.punctuation),
        ('357', SyntaxToken.number),
      ]);
    });
  });
}

/// Colouring for the text inside a diff line.
///
/// One line at a time and never across two: a hunk is not a file, the line
/// above a line in a hunk may not be the line above it in the file, and a
/// highlighter that carries a guess over a hunk boundary is a highlighter that
/// lies. So there is no open-string state and no open-block state between
/// calls; a line that opens a block comment and does not close it is coloured
/// to the end of itself and no further.
///
/// What it cannot place it leaves [SyntaxToken.plain], which is the colour the
/// whole line used to be. Being wrong is worse than being quiet here: the two
/// colours that mean added and removed are the ones the screen exists for.
library;

enum SyntaxToken {
  plain,
  keyword,
  type,
  string,
  number,
  comment,
  punctuation,
  annotation,
}

typedef SyntaxSpan = ({String text, SyntaxToken token});

/// How one family of files is read. Not a grammar — the six shapes that carry
/// most of what a diff shows, and nothing that needs to see two lines at once.
class SyntaxLanguage {
  const SyntaxLanguage({
    required this.keywords,
    this.lineComments = const ['//'],
    this.blockComments = true,
    this.quotes = const ['"', "'"],
    this.annotations = false,
    this.capitalsAreTypes = true,
  });

  final Set<String> keywords;
  final List<String> lineComments;

  /// `/* … */`, which is also what makes a `*` at the head of a line a
  /// continuation rather than a multiplication.
  final bool blockComments;
  final List<String> quotes;

  /// `@override`, `@Component` — a word the language marks with a sigil.
  final bool annotations;

  /// A leading capital is a type in most of what this app is written against.
  /// Off for the languages where it is a variable as often as not.
  final bool capitalsAreTypes;
}

const _dartKeywords = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

const _jsKeywords = {
  'as',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'declare',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'from',
  'function',
  'get',
  'if',
  'implements',
  'import',
  'in',
  'instanceof',
  'interface',
  'let',
  'new',
  'null',
  'of',
  'private',
  'protected',
  'public',
  'readonly',
  'return',
  'satisfies',
  'set',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'type',
  'typeof',
  'undefined',
  'var',
  'void',
  'while',
  'yield',
};

const _goKeywords = {
  'break',
  'case',
  'chan',
  'const',
  'continue',
  'default',
  'defer',
  'else',
  'fallthrough',
  'false',
  'for',
  'func',
  'go',
  'goto',
  'if',
  'import',
  'interface',
  'map',
  'nil',
  'package',
  'range',
  'return',
  'select',
  'struct',
  'switch',
  'true',
  'type',
  'var',
};

const _rustKeywords = {
  'as',
  'async',
  'await',
  'break',
  'const',
  'continue',
  'crate',
  'dyn',
  'else',
  'enum',
  'extern',
  'false',
  'fn',
  'for',
  'if',
  'impl',
  'in',
  'let',
  'loop',
  'match',
  'mod',
  'move',
  'mut',
  'pub',
  'ref',
  'return',
  'self',
  'static',
  'struct',
  'super',
  'trait',
  'true',
  'type',
  'unsafe',
  'use',
  'where',
  'while',
};

const _pythonKeywords = {
  'and',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'class',
  'continue',
  'def',
  'del',
  'elif',
  'else',
  'except',
  'False',
  'finally',
  'for',
  'from',
  'global',
  'if',
  'import',
  'in',
  'is',
  'lambda',
  'None',
  'nonlocal',
  'not',
  'or',
  'pass',
  'raise',
  'return',
  'True',
  'try',
  'while',
  'with',
  'yield',
};

const _cKeywords = {
  'abstract',
  'break',
  'case',
  'catch',
  'char',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'double',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'float',
  'for',
  'fun',
  'if',
  'implements',
  'import',
  'int',
  'interface',
  'internal',
  'let',
  'long',
  'namespace',
  'new',
  'null',
  'object',
  'override',
  'package',
  'private',
  'protected',
  'public',
  'return',
  'sealed',
  'short',
  'static',
  'struct',
  'super',
  'switch',
  'this',
  'throw',
  'throws',
  'true',
  'try',
  'typedef',
  'union',
  'using',
  'val',
  'var',
  'virtual',
  'void',
  'while',
};

const _shellKeywords = {
  'case',
  'do',
  'done',
  'elif',
  'else',
  'esac',
  'exec',
  'exit',
  'export',
  'fi',
  'for',
  'function',
  'if',
  'in',
  'local',
  'read',
  'readonly',
  'return',
  'set',
  'shift',
  'then',
  'unset',
  'until',
  'while',
};

const _dataKeywords = {'false', 'null', 'true', 'no', 'off', 'on', 'yes'};

const _sqlKeywords = {
  'and',
  'as',
  'asc',
  'by',
  'create',
  'delete',
  'desc',
  'distinct',
  'drop',
  'exists',
  'from',
  'group',
  'having',
  'index',
  'inner',
  'insert',
  'into',
  'join',
  'left',
  'limit',
  'not',
  'null',
  'on',
  'or',
  'order',
  'primary',
  'select',
  'set',
  'table',
  'union',
  'update',
  'values',
  'where',
};

const _dart = SyntaxLanguage(keywords: _dartKeywords, annotations: true);
const _js = SyntaxLanguage(keywords: _jsKeywords, quotes: ['"', "'", '`']);
const _go = SyntaxLanguage(keywords: _goKeywords, quotes: ['"', '`']);
const _rust = SyntaxLanguage(keywords: _rustKeywords, annotations: true);
const _python = SyntaxLanguage(
  keywords: _pythonKeywords,
  lineComments: ['#'],
  blockComments: false,
  annotations: true,
);
const _cLike = SyntaxLanguage(keywords: _cKeywords, annotations: true);
const _shell = SyntaxLanguage(
  keywords: _shellKeywords,
  lineComments: ['#'],
  blockComments: false,
  capitalsAreTypes: false,
);
const _data = SyntaxLanguage(
  keywords: _dataKeywords,
  lineComments: ['#'],
  blockComments: false,
  capitalsAreTypes: false,
);
const _json = SyntaxLanguage(
  keywords: _dataKeywords,
  lineComments: [],
  blockComments: false,
  quotes: ['"'],
  capitalsAreTypes: false,
);
const _sql = SyntaxLanguage(
  keywords: _sqlKeywords,
  lineComments: ['--'],
  capitalsAreTypes: false,
);

/// The language a path is in, by its extension and nothing else. A file the
/// app does not know is not guessed at: it is left uncoloured.
SyntaxLanguage? languageOf(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  // A dotfile is read by its own name — `.zshrc`, `.gitignore` — which is the
  // whole of it with the leading dot off, not an extension.
  final extension = (dot > 0
          ? name.substring(dot + 1)
          : name.startsWith('.')
          ? name.substring(1)
          : name)
      .toLowerCase();
  return switch (extension) {
    'dart' => _dart,
    'js' || 'jsx' || 'mjs' || 'cjs' || 'ts' || 'tsx' => _js,
    'go' => _go,
    'rs' => _rust,
    'py' || 'pyi' => _python,
    'c' ||
    'h' ||
    'cc' ||
    'cpp' ||
    'hpp' ||
    'cs' ||
    'java' ||
    'kt' ||
    'kts' ||
    'scala' ||
    'swift' ||
    'm' ||
    'mm' => _cLike,
    'sh' || 'bash' || 'zsh' || 'bashrc' || 'zshrc' || 'profile' => _shell,
    'yaml' || 'yml' || 'toml' || 'ini' || 'cfg' || 'conf' => _data,
    'json' => _json,
    'sql' => _sql,
    _ => null,
  };
}

/// One line, cut into runs of a single colour. A null [language] gives back the
/// line whole and plain, which is what every line looked like before.
List<SyntaxSpan> highlight(String line, SyntaxLanguage? language) {
  if (language == null || line.isEmpty) {
    return [(text: line, token: SyntaxToken.plain)];
  }
  return _Scanner(line, language).run();
}

class _Scanner {
  _Scanner(this.line, this.language);

  final String line;
  final SyntaxLanguage language;
  final _spans = <SyntaxSpan>[];

  int _start = 0;
  int _at = 0;

  List<SyntaxSpan> run() {
    // A line that opens inside a block comment cannot be told from one that
    // does not, so the two shapes the eye reads as a continuation — a line
    // whose first non-space is `*`, and one that closes a block — are taken
    // whole. It is the one guess worth making: doc comments are most of what
    // a diff shows of a comment.
    if (language.blockComments && _isBlockContinuation()) {
      return [(text: line, token: SyntaxToken.comment)];
    }
    while (_at < line.length) {
      final char = line[_at];
      if (_comment()) break;
      if (language.quotes.contains(char)) {
        _string(char);
      } else if (_isDigit(char) && !_isWordChar(_previous)) {
        _number();
      } else if (language.annotations && char == '@') {
        _annotation();
      } else if (_isWordStart(char)) {
        _word();
      } else if (char == ' ' || char == '\t') {
        _take(SyntaxToken.plain, _at + 1);
      } else {
        _take(SyntaxToken.punctuation, _at + 1);
      }
    }
    _flush(line.length);
    return _spans;
  }

  String get _previous => _at == 0 ? '' : line[_at - 1];

  bool _isBlockContinuation() {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('*')) return true;
    return trimmed.contains('*/') && !trimmed.contains('/*');
  }

  /// True when the rest of the line is a comment, which ends the scan.
  bool _comment() {
    for (final marker in language.lineComments) {
      if (line.startsWith(marker, _at)) {
        _flush(_at);
        _spans.add((text: line.substring(_at), token: SyntaxToken.comment));
        _at = line.length;
        _start = line.length;
        return true;
      }
    }
    if (language.blockComments && line.startsWith('/*', _at)) {
      final close = line.indexOf('*/', _at + 2);
      _flush(_at);
      final end = close == -1 ? line.length : close + 2;
      _spans.add((text: line.substring(_at, end), token: SyntaxToken.comment));
      _at = end;
      _start = end;
      return close == -1;
    }
    return false;
  }

  void _string(String quote) {
    var end = _at + 1;
    while (end < line.length) {
      if (line[end] == r'\') {
        end += 2;
        continue;
      }
      if (line[end] == quote) {
        end += 1;
        break;
      }
      end += 1;
    }
    // A quote with no partner is still a string to the end of the line: the
    // rest of it is in the next line of the file, which is not here.
    _take(SyntaxToken.string, end > line.length ? line.length : end);
  }

  void _number() {
    var end = _at;
    while (end < line.length && _isNumberChar(line[end])) {
      end += 1;
    }
    _take(SyntaxToken.number, end);
  }

  void _annotation() {
    var end = _at + 1;
    while (end < line.length && _isWordChar(line[end])) {
      end += 1;
    }
    if (end == _at + 1) {
      _take(SyntaxToken.punctuation, end);
      return;
    }
    _take(SyntaxToken.annotation, end);
  }

  void _word() {
    var end = _at;
    while (end < line.length && _isWordChar(line[end])) {
      end += 1;
    }
    final word = line.substring(_at, end);
    final token = language.keywords.contains(word)
        ? SyntaxToken.keyword
        : language.capitalsAreTypes && _isUpper(word[0])
        ? SyntaxToken.type
        : SyntaxToken.plain;
    _take(token, end);
  }

  /// Closes whatever plain run was open, adds [end] - [_at] as [token], and
  /// moves on.
  void _take(SyntaxToken token, int end) {
    if (token == SyntaxToken.plain) {
      _at = end;
      return;
    }
    _flush(_at);
    _spans.add((text: line.substring(_at, end), token: token));
    _at = end;
    _start = end;
  }

  void _flush(int end) {
    if (end <= _start) return;
    _spans.add((text: line.substring(_start, end), token: SyntaxToken.plain));
    _start = end;
  }

  static bool _isDigit(String c) =>
      c.compareTo('0') >= 0 && c.compareTo('9') <= 0;

  static bool _isUpper(String c) =>
      c.compareTo('A') >= 0 && c.compareTo('Z') <= 0;

  static bool _isWordStart(String c) =>
      _isUpper(c) ||
      (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
      c == '_' ||
      c == r'$';

  static bool _isWordChar(String c) => _isWordStart(c) || _isDigit(c);

  static bool _isNumberChar(String c) =>
      _isWordChar(c) || c == '.' || c == 'x' || c == 'X';
}

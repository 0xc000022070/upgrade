/// Colouring for code, over the vendored grammar engine.
///
/// [highlight] takes one line and never sees the one above it: the line above a line in a
/// hunk may not be the line above it in the checkout. [highlightFile] takes the whole
/// file, which is the only way a block comment or a string that runs over a line break is
/// coloured to where it ends. What the grammar cannot place is left [SyntaxToken.plain].
library;

import 'dart:isolate';

import 'package:striked_highlight/striked_highlight.dart';
import 'package:striked_highlight/languages/all.dart';

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

class SyntaxLanguage {
  const SyntaxLanguage(this.name, {this.blockComments = false});

  final String name;

  /// `/* … */` is in the language, which is also what makes a `*` at the head of a line on
  /// its own a continuation rather than a multiplication.
  final bool blockComments;

  @override
  bool operator ==(Object other) =>
      other is SyntaxLanguage && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

const _dart = SyntaxLanguage('dart', blockComments: true);
const _javascript = SyntaxLanguage('javascript', blockComments: true);
const _typescript = SyntaxLanguage('typescript', blockComments: true);
const _go = SyntaxLanguage('go', blockComments: true);
const _rust = SyntaxLanguage('rust', blockComments: true);
const _python = SyntaxLanguage('python');
const _c = SyntaxLanguage('c', blockComments: true);
const _cpp = SyntaxLanguage('cpp', blockComments: true);
const _java = SyntaxLanguage('java', blockComments: true);
const _kotlin = SyntaxLanguage('kotlin', blockComments: true);
const _scala = SyntaxLanguage('scala', blockComments: true);
const _bash = SyntaxLanguage('bash');
const _yaml = SyntaxLanguage('yaml');
const _ini = SyntaxLanguage('ini');
const _json = SyntaxLanguage('json');
const _sql = SyntaxLanguage('sql', blockComments: true);
const _nix = SyntaxLanguage('nix', blockComments: true);
const _lua = SyntaxLanguage('lua');
const _markdown = SyntaxLanguage('markdown');
const _dockerfile = SyntaxLanguage('dockerfile');
const _makefile = SyntaxLanguage('makefile');
const _css = SyntaxLanguage('css', blockComments: true);
const _scss = SyntaxLanguage('scss', blockComments: true);
const _xml = SyntaxLanguage('xml');
const _protobuf = SyntaxLanguage('protobuf', blockComments: true);
const _graphql = SyntaxLanguage('graphql');
const _properties = SyntaxLanguage('properties');
const _diff = SyntaxLanguage('diff');
const _http = SyntaxLanguage('http');
const _nginx = SyntaxLanguage('nginx');

/// By extension or, for the files that have none, by name. A file the app does not know
/// is not guessed at: it is left uncoloured.
SyntaxLanguage? languageOf(String path) {
  final name = path.split('/').last.toLowerCase();
  switch (name) {
    case 'dockerfile' || 'containerfile':
      return _dockerfile;
    case 'makefile' || 'gnumakefile':
      return _makefile;
    case 'nginx.conf':
      return _nginx;
  }
  final dot = name.lastIndexOf('.');
  // A dotfile is read by its own name — `.zshrc`, `.gitignore` — which is the
  // whole of it with the leading dot off, not an extension.
  final extension = dot > 0
      ? name.substring(dot + 1)
      : name.startsWith('.')
      ? name.substring(1)
      : name;
  return switch (extension) {
    'dart' => _dart,
    'js' || 'jsx' || 'mjs' || 'cjs' => _javascript,
    'ts' || 'tsx' || 'mts' || 'cts' => _typescript,
    'go' => _go,
    'rs' => _rust,
    'py' || 'pyi' => _python,
    'c' || 'h' => _c,
    'cc' || 'cpp' || 'cxx' || 'hh' || 'hpp' || 'hxx' => _cpp,
    'java' => _java,
    'kt' || 'kts' => _kotlin,
    'scala' || 'sbt' => _scala,
    'sh' ||
    'bash' ||
    'zsh' ||
    'bashrc' ||
    'zshrc' ||
    'zshenv' ||
    'zprofile' ||
    'profile' => _bash,
    'yaml' || 'yml' => _yaml,
    'toml' || 'ini' || 'cfg' || 'conf' || 'gitconfig' || 'editorconfig' => _ini,
    'json' || 'jsonc' => _json,
    'sql' => _sql,
    'nix' => _nix,
    'lua' || 'luau' => _lua,
    'md' || 'markdown' => _markdown,
    'dockerfile' => _dockerfile,
    'mk' => _makefile,
    'css' => _css,
    'scss' => _scss,
    'xml' || 'html' || 'htm' || 'xhtml' || 'svg' || 'plist' => _xml,
    'proto' => _protobuf,
    'graphql' || 'gql' => _graphql,
    'properties' => _properties,
    'diff' || 'patch' => _diff,
    'http' => _http,
    _ => null,
  };
}

SyntaxLanguage? languageNamed(String? name) => switch (name) {
  'dart' => _dart,
  'javascript' || 'jsx' => _javascript,
  'typescript' || 'tsx' => _typescript,
  'go' => _go,
  'rust' => _rust,
  'python' => _python,
  'c' => _c,
  'cpp' => _cpp,
  'java' => _java,
  'kotlin' => _kotlin,
  'scala' => _scala,
  'bash' || 'sh' || 'shell' || 'zsh' => _bash,
  'yaml' => _yaml,
  'toml' || 'ini' => _ini,
  'json' => _json,
  'sql' => _sql,
  'nix' => _nix,
  'lua' => _lua,
  'markdown' => _markdown,
  'dockerfile' => _dockerfile,
  'make' || 'makefile' => _makefile,
  'css' => _css,
  'scss' => _scss,
  'html' || 'xml' => _xml,
  'proto' || 'protobuf' => _protobuf,
  'graphql' => _graphql,
  _ => null,
};

List<SyntaxSpan> highlight(String line, SyntaxLanguage? language) {
  if (language == null || line.isEmpty) return [_plain(line)];
  // A line that opens inside a block comment cannot be told from one that does
  // not, so the two shapes the eye reads as a continuation — a line whose first
  // non-space is `*`, and one that closes a block — are taken whole.
  if (language.blockComments && _isBlockContinuation(line)) {
    return [(text: line, token: SyntaxToken.comment)];
  }
  return _run(line, language) ?? [_plain(line)];
}

/// Below [inlineBytes] on the spot; above, on another isolate, so a long file never holds
/// a frame. One entry per line of `text.split('\n')`, in order.
Future<List<List<SyntaxSpan>>> highlightFile(
  String text,
  SyntaxLanguage? language, {
  int inlineBytes = 16 * 1024,
}) {
  if (language == null) {
    return Future.value([
      for (final line in text.split('\n')) [_plain(line)],
    ]);
  }
  if (text.length <= inlineBytes) {
    return Future.value(highlightLines(text, language));
  }
  return Isolate.run(() => highlightLines(text, language));
}

List<List<SyntaxSpan>> highlightLines(String text, SyntaxLanguage language) {
  final spans = _run(text, language);
  if (spans == null) {
    return [
      for (final line in text.split('\n')) [_plain(line)],
    ];
  }
  // The runs are cut again at every line break, so a comment that spans three
  // lines is three comment runs, one per line, and an empty line is an empty
  // plain run rather than nothing.
  final lines = <List<SyntaxSpan>>[[]];
  for (final span in spans) {
    final pieces = span.text.split('\n');
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) lines.add([]);
      if (pieces[i].isNotEmpty) {
        lines.last.add((text: pieces[i], token: span.token));
      }
    }
  }
  for (final line in lines) {
    if (line.isEmpty) line.add(_plain(''));
  }
  return lines;
}

SyntaxSpan _plain(String text) => (text: text, token: SyntaxToken.plain);

bool _isBlockContinuation(String line) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('*')) return true;
  return trimmed.contains('*/') && !trimmed.contains('/*');
}

/// One engine per isolate, built the first time it is asked for. The grammars compile
/// themselves in place on first use, so they are not shared across engines.
final _engine = highlighterWithAllLanguages();

/// Null when the engine gave up part way — it swallows a grammar's own errors and hands
/// back what it had — since a partial colouring is a colouring that drops text.
List<SyntaxSpan>? _run(String code, SyntaxLanguage language) {
  final HighlightResult result;
  try {
    result = _engine.highlight(code: code, language: language.name);
  } on Object {
    return null;
  }
  if (result.errorRaised != null) return null;
  final spans = <SyntaxSpan>[];
  var length = 0;
  for (final span in result.spans()) {
    length += span.text.length;
    final token = _tokenOf(span.scopes);
    if (spans.isNotEmpty && spans.last.token == token) {
      spans.last = (text: spans.last.text + span.text, token: token);
    } else {
      spans.add((text: span.text, token: token));
    }
  }
  return length == code.length ? spans : null;
}

/// The innermost scope that has a colour wins; one that does not is looked through to the
/// scope around it, so a string's escape is a string and a keyword inside a function head
/// is a keyword. The scopes mapped to plain are the ones that stop the walk: text inside
/// `${…}` is code again, not more of the string.
SyntaxToken _tokenOf(List<String> scopes) {
  for (final scope in scopes.reversed) {
    final token = _byScope[scope] ?? _byScope[scope.split('.').first];
    if (token != null) return token;
  }
  return SyntaxToken.plain;
}

const _byScope = <String, SyntaxToken>{
  'keyword': SyntaxToken.keyword,
  'built_in': SyntaxToken.keyword,
  'literal': SyntaxToken.keyword,
  'selector-tag': SyntaxToken.keyword,
  'template-tag': SyntaxToken.keyword,
  'meta.keyword': SyntaxToken.keyword,
  'type': SyntaxToken.type,
  'class': SyntaxToken.type,
  'title.class': SyntaxToken.type,
  'title.class.inherited': SyntaxToken.type,
  'name': SyntaxToken.type,
  'symbol': SyntaxToken.type,
  'string': SyntaxToken.string,
  'char': SyntaxToken.string,
  'regexp': SyntaxToken.string,
  'link': SyntaxToken.string,
  'quote': SyntaxToken.string,
  'meta.string': SyntaxToken.string,
  'number': SyntaxToken.number,
  'comment': SyntaxToken.comment,
  'meta': SyntaxToken.annotation,
  'doctag': SyntaxToken.annotation,
  'attr': SyntaxToken.annotation,
  'attribute': SyntaxToken.annotation,
  'bullet': SyntaxToken.annotation,
  'section': SyntaxToken.annotation,
  'selector-class': SyntaxToken.annotation,
  'selector-id': SyntaxToken.annotation,
  'selector-attr': SyntaxToken.annotation,
  'selector-pseudo': SyntaxToken.annotation,
  'punctuation': SyntaxToken.punctuation,
  'tag': SyntaxToken.punctuation,
  'operator': SyntaxToken.punctuation,
  'subst': SyntaxToken.plain,
  'params': SyntaxToken.plain,
  'variable': SyntaxToken.plain,
  'property': SyntaxToken.plain,
  'title': SyntaxToken.plain,
  'function': SyntaxToken.plain,
  'formula': SyntaxToken.plain,
  'code': SyntaxToken.plain,
  'emphasis': SyntaxToken.plain,
  'strong': SyntaxToken.plain,
  'addition': SyntaxToken.plain,
  'deletion': SyntaxToken.plain,
};

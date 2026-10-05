import '../upgrade_highlight.dart';
import 'bash.dart';
import 'c.dart';
import 'cpp.dart';
import 'css.dart';
import 'dart.dart';
import 'diff.dart';
import 'dockerfile.dart';
import 'go.dart';
import 'graphql.dart';
import 'http.dart';
import 'ini.dart';
import 'java.dart';
import 'javascript.dart';
import 'json.dart';
import 'kotlin.dart';
import 'lua.dart';
import 'makefile.dart';
import 'markdown.dart';
import 'nginx.dart';
import 'nix.dart';
import 'plaintext.dart';
import 'properties.dart';
import 'protobuf.dart';
import 'python.dart';
import 'rust.dart';
import 'scala.dart';
import 'scss.dart';
import 'shell.dart';
import 'sql.dart';
import 'typescript.dart';
import 'xml.dart';
import 'yaml.dart';

/// Every grammar shipped, by its highlight.js name. Registered together
/// because grammars reach into each other by name for sub-languages
/// (markdown fences, xml script blocks, http bodies).
final Map<String, Mode> builtinLanguages = {
  'bash': langBash,
  'c': langC,
  'cpp': langCpp,
  'css': langCss,
  'dart': langDart,
  'diff': langDiff,
  'dockerfile': langDockerfile,
  'go': langGo,
  'graphql': langGraphql,
  'http': langHttp,
  'ini': langIni,
  'java': langJava,
  'javascript': langJavascript,
  'json': langJson,
  'kotlin': langKotlin,
  'lua': langLua,
  'makefile': langMakefile,
  'markdown': langMarkdown,
  'nginx': langNginx,
  'nix': langNix,
  'plaintext': langPlaintext,
  'properties': langProperties,
  'protobuf': langProtobuf,
  'python': langPython,
  'rust': langRust,
  'scala': langScala,
  'scss': langScss,
  'shell': langShell,
  'sql': langSql,
  'typescript': langTypescript,
  'xml': langXml,
  'yaml': langYaml,
};

/// An engine with every shipped grammar registered.
Highlight highlighterWithAllLanguages() {
  final engine = Highlight();
  builtinLanguages.forEach(engine.registerLanguage);
  return engine;
}

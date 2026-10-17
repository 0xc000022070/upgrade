/// A highlight.js grammar engine in Dart, without a renderer of its own: a
/// result is a tree of scoped text, read out as [HighlightSpan] runs.
library;

import 'dart:math';

part 'src/_before_match.dart';
part 'src/_compile_keywords.dart';
part 'src/_compiler_extensions.dart';
part 'src/_mode_compiler.dart';
part 'src/_multi_class.dart';
part 'src/_regex.dart';
part 'src/_response.dart';
part 'src/highlight.dart';
part 'src/mode.dart';
part 'src/modes.dart';
part 'src/spans.dart';
part 'src/token_tree.dart';

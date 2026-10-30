part of '../upgrade_highlight.dart';

/// One run of text and the scopes open over it, outermost first. A run with
/// no scope is text the grammar had nothing to say about.
class HighlightSpan {
  const HighlightSpan(this.text, this.scopes);

  final String text;
  final List<String> scopes;

  @override
  String toString() => '$scopes:${text.replaceAll('\n', r'\n')}';
}

extension HighlightSpans on HighlightResult {
  /// The result flattened into runs, in reading order, covering every
  /// character of the code once.
  List<HighlightSpan> spans() {
    final out = <HighlightSpan>[];
    final open = <String>[];
    void walk(dynamic node) {
      if (node is String) {
        if (node.isNotEmpty) out.add(HighlightSpan(node, List.of(open)));
      } else if (node is DataNode) {
        final scope = node.scope;
        if (scope != null) open.add(scope);
        for (final child in node.children) {
          walk(child);
        }
        if (scope != null) open.removeLast();
      }
    }

    walk((_emitter as _TokenTree).rootNode);
    return out;
  }
}

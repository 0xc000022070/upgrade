class DropText {
  const DropText(this.title, this.links);

  final String title;
  final List<String> links;
}

// A blank line cannot separate entries: an item's own text may carry one. Only the ends of
// an entry are trimmed, so spacing the user typed inside a drop survives the copy.
const _rule = '\n\n---\n\n';

/// Deliberately not `sendPrompt` and does not call it: a send also names the host paths
/// its pictures landed under, which mean nothing where the user would paste.
String dropClipboardText(Iterable<DropText> drops) =>
    drops.map(_entry).join(_rule);

String _entry(DropText drop) {
  final title = drop.title.trim();
  return drop.links.isEmpty ? title : '$title\n\n${drop.links.join('\n')}';
}

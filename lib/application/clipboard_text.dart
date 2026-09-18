class DropText {
  const DropText(this.title, this.links);

  final String title;
  final List<String> links;
}

/// Deliberately not `sendPrompt` and does not call it: a send also names the host paths
/// its pictures landed under, which mean nothing where the user would paste.
String dropClipboardText(Iterable<DropText> drops) =>
    drops.map(_entry).join('\n\n');

String _entry(DropText drop) => drop.links.isEmpty
    ? drop.title
    : '${drop.title}\n\n${drop.links.join('\n')}';

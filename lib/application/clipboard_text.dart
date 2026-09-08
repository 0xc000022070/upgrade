/// One drop on its way to the clipboard: the text as it was typed and the
/// links attached to it. Images are not here — an image attachment's value is a
/// path under the app's support directory, which means nothing anywhere the
/// user could paste it.
class DropText {
  const DropText(this.title, this.links);

  final String title;
  final List<String> links;
}

/// What a copy leaves on the phone's clipboard.
///
/// One drop is its title, then a blank line and its links one per line, which
/// is the shape a send hands an agent for the same reason: nothing is wrapped
/// around the user's own words. It is deliberately not `sendPrompt` and does
/// not call it — a send also names the host paths its pictures landed under,
/// and a path on somebody else's machine is not something a phone can paste.
///
/// Several drops are joined by a blank line, in the order the panel draws
/// them.
String dropClipboardText(Iterable<DropText> drops) =>
    drops.map(_entry).join('\n\n');

String _entry(DropText drop) => drop.links.isEmpty
    ? drop.title
    : '${drop.title}\n\n${drop.links.join('\n')}';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../platform/vnc/keysyms.dart';

/// One key on the strip: what it sends, and whether it is drawn as a tracked
/// word or as one of the artist's glyphs.
class StripKey {
  const StripKey(this.label, this.keysym, {this.icon});

  final String label;
  final int keysym;

  /// The four arrows carry `hl-arrow-*` and no word. The label stays
  /// even then — it is what the key is called in a test and to a screen reader,
  /// and a glyph is not either of those.
  final DazzleIcons? icon;
}

/// One cell of the strip's grid: a key that sends a keysym, a sticky modifier,
/// or the gap the arrows are laid out around.
class StripCell {
  const StripCell.key(StripKey this.key) : modifier = null;
  const StripCell.modifier(StickyModifier this.modifier) : key = null;
  const StripCell.gap() : key = null, modifier = null;

  final StripKey? key;
  final StickyModifier? modifier;
}

/// Two rows of six equal columns, the arrangement AVNC uses: the arrows form an
/// inverted T in the last three columns, and the cell above the left arrow
/// stays empty — AVNC puts `HOME` there and the user does not use it.
///
/// `ENTER` is not here: Return belongs to the keyboard's own return key, which
/// is closer to the hand than a button on a strip above it. `PGUP` and `PGDN`
/// are left out for the same reason as `HOME`.
const stripRows = <List<StripCell>>[
  [
    StripCell.key(StripKey('ESC', Keysyms.escape)),
    StripCell.key(StripKey('TAB', Keysyms.tab)),
    StripCell.modifier(StickyModifier.shift),
    StripCell.gap(),
    StripCell.key(StripKey('UP', Keysyms.up, icon: DazzleIcons.arrowUp)),
    StripCell.key(StripKey('END', Keysyms.end)),
  ],
  [
    StripCell.modifier(StickyModifier.superKey),
    StripCell.modifier(StickyModifier.ctrl),
    StripCell.modifier(StickyModifier.alt),
    StripCell.key(StripKey('LEFT', Keysyms.left, icon: DazzleIcons.arrowLeft)),
    StripCell.key(StripKey('DOWN', Keysyms.down, icon: DazzleIcons.arrowDown)),
    StripCell.key(
      StripKey('RIGHT', Keysyms.right, icon: DazzleIcons.arrowRight),
    ),
  ],
];

/// `SUPER` draws the artist's ⌘-like mark and no word. The other three
/// modifiers stay words, so this is a lookup rather than a field on the enum —
/// [StickyModifier] is a transport concern and knows nothing about assets.
DazzleIcons? stickyIcon(StickyModifier modifier) =>
    modifier == StickyModifier.superKey ? DazzleIcons.superKey : null;

/// The strip, the soft keyboard, and the text the IME produces.
///
/// A hidden [EditableText] is the only way to a soft keyboard's characters:
/// Android delivers typing as editing operations on a text field, not as key
/// events, so each typed character goes as an X keysym read off the field's
/// value as it changes.
///
/// The strip and the keyboard are independent, which is why both live here and
/// neither owns the other: the field is mounted for as long as the
/// route is, so raising the strip never raises the keyboard and hiding the
/// keyboard never takes the strip down with it.
class KeysLayer extends StatefulWidget {
  const KeysLayer({
    super.key,
    required this.stripVisible,
    required this.keyboardOpen,
    required this.onCharacter,
    required this.onKeysym,
    required this.onKeyboardClosed,
    this.inertModifiers = const {},
  });

  final bool stripVisible;
  final bool keyboardOpen;

  /// Modifiers the caller has no use for: drawn dim and not armable, so the
  /// strip keeps its shape wherever it is used rather than losing a cell and
  /// sliding the arrows out from under the thumb. Empty by default, which is
  /// every strip that wants all four.
  final Set<StickyModifier> inertModifiers;

  final void Function(String character, Set<StickyModifier> sticky) onCharacter;
  final void Function(int keysym, Set<StickyModifier> sticky) onKeysym;

  /// The system back gesture and the IME's own hide close the keyboard without
  /// asking the rail, and the rail's keyboard toggle has to read as off
  /// afterwards. Reported from here because losing focus is the only signal
  /// either of those leaves.
  final VoidCallback onKeyboardClosed;

  @override
  State<KeysLayer> createState() => _KeysLayerState();
}

class _KeysLayerState extends State<KeysLayer> {
  /// A run of zero-width spaces the IME can delete into, so a backspace with
  /// nothing typed still arrives as an editing change rather than as nothing.
  static const _base = '​​​​​​​​';

  final _focus = FocusNode();
  late final TextEditingController _text = TextEditingController(text: _base);
  final _sticky = <StickyModifier>{};
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    if (widget.keyboardOpen) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focus.requestFocus(),
      );
    }
  }

  @override
  void didUpdateWidget(KeysLayer old) {
    super.didUpdateWidget(old);
    if (widget.keyboardOpen == old.keyboardOpen) return;
    if (widget.keyboardOpen) {
      _focus.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus && widget.keyboardOpen) widget.onKeyboardClosed();
  }

  void _onChanged(String value) {
    if (_resetting) return;
    if (value.length > _base.length) {
      // By rune, not by code unit: an emoji is one keysym, and half of one is
      // not a character the host can be sent.
      for (final rune in value.substring(_base.length).runes) {
        // The field takes a multiline input type so Gboard offers ↵
        // where it used to offer a checkmark that sent nothing. What arrives is
        // a newline in the text, and it goes as Return — a keysym, never a
        // character, because `\n` is a C0 control that has no keysym of its own.
        if (rune == 0x0A) {
          _send(() => widget.onKeysym(Keysyms.enter, Set.of(_sticky)));
          continue;
        }
        final character = String.fromCharCode(rune);
        _send(() => widget.onCharacter(character, Set.of(_sticky)));
      }
    } else if (value.length < _base.length) {
      for (var i = value.length; i < _base.length; i++) {
        _send(() => widget.onKeysym(Keysyms.backSpace, Set.of(_sticky)));
      }
    }
    // Back to the sentinel, so the field never grows and the next change is
    // read against the same baseline.
    _resetting = true;
    _text.value = const TextEditingValue(
      text: _base,
      selection: TextSelection.collapsed(offset: _base.length),
    );
    _resetting = false;
  }

  /// Every send clears the sticky modifiers: they are sticky "for one
  /// following key", so the key that just went is the one they were for.
  void _send(VoidCallback body) {
    body();
    if (_sticky.isNotEmpty) setState(_sticky.clear);
  }

  /// Offstage would take it out of the tree and the keyboard with it.
  /// Zero-sized and still focusable is what keeps the IME attached.
  Widget get _field => SizedBox(
    width: 0,
    height: 0,
    child: EditableText(
      controller: _text,
      focusNode: _focus,
      style: context.tokens.label,
      cursorColor: context.tokens.accent,
      backgroundCursorColor: context.tokens.borderSubtle,
      onChanged: _onChanged,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      // Return: multiline with the newline action is what makes the
      // IME draw ↵ and insert a `\n` rather than draw a checkmark and finalise
      // the edit. `maxLines: null` is part of the same switch — [EditableText]
      // treats a single-line field's newline action as "done" and would unfocus
      // instead of letting the character through.
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      maxLines: null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    // The field holds its own slot whether the strip is up or not. Moving it —
    // returning it bare when the strip is hidden, nesting it in the strip's Row
    // when it is not — reparents the [EditableText], which disposes its element
    // and takes the focus, and with the focus the keyboard: raising the strip
    // would then close the keyboard, which is the one thing the two toggles
    // being independent forbids.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.stripVisible ? _strip() : const SizedBox.shrink(),
        _field,
      ],
    );
  }

  Widget _strip() {
    return Container(
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in stripRows)
            Row(
              children: [
                // Equal columns rather than keys sized to their words: the
                // arrows only read as an inverted T if the grid under them is
                // one, and a scrolling row put the last of them off screen.
                for (final cell in row) Expanded(child: _cell(cell)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _cell(StripCell cell) {
    final modifier = cell.modifier;
    if (modifier != null) {
      if (widget.inertModifiers.contains(modifier)) {
        return KeyCell(
          key: ValueKey('key-${modifier.label}'),
          label: modifier.label,
          icon: stickyIcon(modifier),
          inert: true,
          onTap: () {},
        );
      }
      return KeyCell(
        key: ValueKey('key-${modifier.label}'),
        label: modifier.label,
        icon: stickyIcon(modifier),
        armed: _sticky.contains(modifier),
        onTap: () => setState(() {
          _sticky.contains(modifier)
              ? _sticky.remove(modifier)
              : _sticky.add(modifier);
        }),
      );
    }
    final key = cell.key;
    if (key == null) return const SizedBox(height: TapTargets.minHeight);
    return KeyCell(
      key: ValueKey('key-${key.label}'),
      label: key.label,
      icon: key.icon,
      onTap: () => _send(() => widget.onKeysym(key.keysym, Set.of(_sticky))),
    );
  }
}

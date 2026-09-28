import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../design/components/key_bar.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../platform/vnc/arming.dart';
import '../../platform/vnc/keysyms.dart';
import '../modifier_cell.dart';

typedef _StripKey = ({String label, int keysym, DazzleIcons? icon});

/// `SUPER` is here where the terminal's bar has none: a desktop takes a compositor chord,
/// and that never comes from the IME.
const _stripModifiers = <StickyModifier>[
  StickyModifier.superKey,
  StickyModifier.ctrl,
  StickyModifier.alt,
  StickyModifier.shift,
];

const _stripKeys = <_StripKey>[
  (label: 'ESC', keysym: Keysyms.escape, icon: null),
  (label: 'TAB', keysym: Keysyms.tab, icon: null),
  (label: 'LEFT', keysym: Keysyms.left, icon: DazzleIcons.arrowLeft),
  (label: 'UP', keysym: Keysyms.up, icon: DazzleIcons.arrowUp),
  (label: 'DOWN', keysym: Keysyms.down, icon: DazzleIcons.arrowDown),
  (label: 'RIGHT', keysym: Keysyms.right, icon: DazzleIcons.arrowRight),
  (label: 'END', keysym: Keysyms.end, icon: null),
];

/// A hidden [EditableText] is the only way to a soft keyboard's characters: Android
/// delivers typing as editing operations on a text field, not as key events, so each
/// typed character goes as an X keysym read off the field's value as it changes. The
/// field is mounted for as long as the route is, so raising the strip never raises the
/// keyboard and hiding the keyboard never takes the strip down.
class KeysLayer extends StatefulWidget {
  const KeysLayer({
    super.key,
    required this.stripVisible,
    required this.keyboardOpen,
    required this.onCharacter,
    required this.onKeysym,
    required this.onKeyboardClosed,
  });

  final bool stripVisible;
  final bool keyboardOpen;

  final void Function(String character, Set<StickyModifier> sticky) onCharacter;
  final void Function(int keysym, Set<StickyModifier> sticky) onKeysym;

  /// The system back gesture and the IME's own hide close the keyboard without asking the
  /// rail, and losing focus is the only signal either of those leaves.
  final VoidCallback onKeyboardClosed;

  @override
  State<KeysLayer> createState() => _KeysLayerState();
}

class _KeysLayerState extends State<KeysLayer> {
  /// A run of zero-width spaces the IME can delete into, so a backspace with nothing typed
  /// still arrives as an editing change rather than as nothing.
  static const _base = '​​​​​​​​';

  final _focus = FocusNode();
  late final TextEditingController _text = TextEditingController(text: _base);
  var _arming = const Arming();
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
      // By rune, not by code unit: an emoji is one keysym, and half of one is not a character
      // the host can be sent.
      for (final rune in value.substring(_base.length).runes) {
        // The field takes a multiline input type so Gboard offers ↵ where it used to offer a
        // checkmark that sent nothing. What arrives is a newline in the text, and it goes as
        // Return — a keysym, never a character, because `\n` is a C0 control with no keysym.
        if (rune == 0x0A) {
          _send(() => widget.onKeysym(Keysyms.enter, _arming.sticky));
          continue;
        }
        final character = String.fromCharCode(rune);
        _send(() => widget.onCharacter(character, _arming.sticky));
      }
    } else if (value.length < _base.length) {
      for (var i = value.length; i < _base.length; i++) {
        _send(() => widget.onKeysym(Keysyms.backSpace, _arming.sticky));
      }
    }
    // Back to the sentinel, so the field never grows and the next change is read against the
    // same baseline.
    _resetting = true;
    _text.value = const TextEditingValue(
      text: _base,
      selection: TextSelection.collapsed(offset: _base.length),
    );
    _resetting = false;
  }

  /// Every key spends the arming, the bar's and the IME's alike: the key that just went is
  /// one of the keys it was for.
  void _send(VoidCallback body) {
    body();
    final next = _arming.spent();
    if (!identical(next, _arming)) setState(() => _arming = next);
  }

  /// Offstage would take it out of the tree and the keyboard with it. Zero-sized and still
  /// focusable is what keeps the IME attached.
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
      // `maxLines: null` is part of the same switch: [EditableText] treats a single-line
      // field's newline action as "done" and would unfocus instead of letting the character
      // through.
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      maxLines: null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    // The field holds its own slot whether the strip is up or not. Moving it reparents the
    // [EditableText], which disposes its element and takes the focus, and with the focus the
    // keyboard: raising the strip would then close the keyboard.
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
    return KeyBar(
      keys: [
        for (final modifier in _stripModifiers)
          ModifierCell(
            key: ValueKey('key-${modifier.label}'),
            modifier: modifier,
            arming: _arming,
            onArming: (next) => setState(() => _arming = next),
          ),
        for (final key in _stripKeys)
          KeyCell(
            key: ValueKey('key-${key.label}'),
            label: key.label,
            icon: key.icon,
            minWidth: KeyBar.height,
            padding: KeyBar.cellPadding,
            onTap: () =>
                _send(() => widget.onKeysym(key.keysym, _arming.sticky)),
          ),
      ],
    );
  }
}

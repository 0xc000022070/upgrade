import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/vnc/keysyms.dart';

/// One key on §39.32's strip: a label and what it sends.
class StripKey {
  const StripKey(this.label, this.keysym);

  final String label;
  final int keysym;
}

/// SPEC.md §39.32's strip, in the spec's order: `ESC`, `TAB`, `CTRL`, `ALT`,
/// `SUPER`, the four arrows, `ENTER`. The three modifiers are the sticky ones
/// and are drawn armed; the rest send and are done.
const stripKeys = <StripKey>[
  StripKey('ESC', Keysyms.escape),
  StripKey('TAB', Keysyms.tab),
  StripKey('←', Keysyms.left),
  StripKey('↑', Keysyms.up),
  StripKey('↓', Keysyms.down),
  StripKey('→', Keysyms.right),
  StripKey('ENTER', Keysyms.enter),
];

/// The soft keyboard, the strip above it, and the text the IME produces.
///
/// A hidden [EditableText] is the only way to a soft keyboard's characters:
/// Android delivers typing as editing operations on a text field, not as key
/// events, so §39.32's "each typed character goes as an X keysym" is read off
/// the field's value as it changes.
class KeysStrip extends StatefulWidget {
  const KeysStrip({
    super.key,
    required this.onCharacter,
    required this.onKeysym,
    required this.onClose,
  });

  final void Function(String character, Set<StickyModifier> sticky)
  onCharacter;
  final void Function(int keysym, Set<StickyModifier> sticky) onKeysym;
  final VoidCallback onClose;

  @override
  State<KeysStrip> createState() => _KeysStripState();
}

class _KeysStripState extends State<KeysStrip> {
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
    // §39.32: `KEYS` opens the soft keyboard. Nothing else on the route takes
    // focus, so requesting it here is what raises it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (_resetting) return;
    if (value.length > _base.length) {
      // By rune, not by code unit: an emoji is one keysym, and half of one is
      // not a character the host can be sent.
      for (final rune in value.substring(_base.length).runes) {
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

  /// Every send clears the sticky modifiers: §39.32 makes them sticky "for one
  /// following key", so the key that just went is the one they were for.
  void _send(VoidCallback body) {
    body();
    if (_sticky.isNotEmpty) setState(_sticky.clear);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: HotlineColors.surfacePrimary,
        border: Border(
          top: BorderSide(color: HotlineColors.borderSubtle),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final modifier in StickyModifier.values)
                    _StripButton(
                      label: modifier.label,
                      armed: _sticky.contains(modifier),
                      onTap: () => setState(() {
                        _sticky.contains(modifier)
                            ? _sticky.remove(modifier)
                            : _sticky.add(modifier);
                      }),
                    ),
                  for (final key in stripKeys)
                    _StripButton(
                      label: key.label,
                      onTap: () => _send(
                        () => widget.onKeysym(key.keysym, Set.of(_sticky)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          _StripButton(label: 'DONE', onTap: widget.onClose),
          // Offstage would take it out of the tree and the keyboard with it.
          // Zero-sized and still focusable is what keeps the IME attached.
          SizedBox(
            width: 0,
            height: 0,
            child: EditableText(
              controller: _text,
              focusNode: _focus,
              style: HotlineText.label,
              cursorColor: HotlineColors.accent,
              backgroundCursorColor: HotlineColors.borderSubtle,
              onChanged: _onChanged,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              // A newline would arrive as a character; §39.32 sends `ENTER`
              // from the strip and as a keysym, so the field never sees one.
              keyboardType: TextInputType.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _StripButton extends StatefulWidget {
  const _StripButton({
    required this.label,
    required this.onTap,
    this.armed = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool armed;

  @override
  State<_StripButton> createState() => _StripButtonState();
}

class _StripButtonState extends State<_StripButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    // §39.23's press, and the same accent for a modifier that is armed: both
    // mean "this key is what the next thing you do goes through".
    final tint = _down || widget.armed
        ? HotlineColors.accent
        : HotlineColors.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: Container(
        constraints: const BoxConstraints(
          minWidth: TapTargets.minHeight,
          minHeight: TapTargets.minHeight,
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: Text(
          widget.label,
          style: HotlineText.panelHeader.copyWith(color: tint),
        ),
      ),
    );
  }
}

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The keyboard is let go when the app leaves the foreground, and one the
/// system forgot to take away is refused on the way back in.
///
/// Android reports the IME as a bottom view inset and the whole app lays out
/// above it: the scaffold shortens, the sheets ride up, the shell's key strip
/// sits on its top edge. A window stopped with the keyboard still up — turning
/// the screen off is the ordinary way to do that — can come back with the inset
/// standing and no keyboard under it, and then every screen draws into a
/// viewport one keyboard short of the display. Nothing in the tree can clear
/// it, because nothing in the tree owns it: the number is the view's, and only
/// a new process or a keyboard that really goes up and down again replaces it.
///
/// So the keyboard goes down before the window stops, which leaves the system
/// nothing to restore.
class KeyboardRelease extends StatefulWidget {
  const KeyboardRelease({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardRelease> createState() => _KeyboardReleaseState();
}

class _KeyboardReleaseState extends State<KeyboardRelease>
    with WidgetsBindingObserver {
  /// Whether the trip out took a keyboard down. It gates the check on the way
  /// back in: an inset with nothing under it is only knowable when the app
  /// itself made sure nothing is under it.
  bool _released = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // Hidden and paused are one trip out and either can be the last one seen,
      // so both do the work and the second finds it done. `inactive` is not
      // among them: the notification shade and a permission dialog raise it
      // without the window ever stopping, and taking the keyboard down for
      // those would cost the user the caret they left mid-word.
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _release();
      case AppLifecycleState.resumed:
        _reconcile();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _release() {
    if (_released) return;
    _released = true;
    if (!_typing) return;
    FocusManager.instance.primaryFocus?.unfocus();
    // The terminal runs its own text input client rather than a field's, so the
    // platform is told directly as well as through the focus node.
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void _reconcile() {
    if (!_released) return;
    _released = false;
    // After the frame: focus settles first, so a field that comes back
    // autofocused is read as asking for the keyboard rather than as an inset
    // nobody claimed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _typing) return;
      if (View.of(context).viewInsets.bottom <= 0) return;
      // An inset nothing is asking for. Whether a keyboard is really under it
      // or the number is a leftover, the same call is the answer to both.
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    });
    // A post-frame callback waits for a frame, and an app resumed onto a still
    // screen may not draw one for a while. The check is the whole point of the
    // resume, so it gets one asked for.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Whether anything on screen is holding the keyboard. A scope with the
  /// primary focus is the shape of "no field has it": scopes are what focus
  /// falls back to, and none of them opens an input connection.
  bool get _typing {
    final focus = FocusManager.instance.primaryFocus;
    return focus != null && focus is! FocusScopeNode;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

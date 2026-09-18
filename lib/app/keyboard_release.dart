import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android reports the IME as a bottom view inset and the whole app lays out above it. A
/// window stopped with the keyboard still up — turning the screen off is the ordinary
/// way — can come back with the inset standing and no keyboard under it, and nothing in
/// the tree can clear it: the number is the view's, and only a new process or a keyboard
/// that really goes up and down again replaces it. So the keyboard goes down before the
/// window stops, which leaves the system nothing to restore.
class KeyboardRelease extends StatefulWidget {
  const KeyboardRelease({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardRelease> createState() => _KeyboardReleaseState();
}

class _KeyboardReleaseState extends State<KeyboardRelease>
    with WidgetsBindingObserver {
  /// Gates the check on the way back in: an inset with nothing under it is only knowable
  /// when the app itself made sure nothing is under it.
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
      // Hidden and paused are one trip out and either can be the last one seen, so both do the
      // work and the second finds it done. `inactive` is not among them: the notification
      // shade and a permission dialog raise it without the window ever stopping.
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
    // The terminal runs its own text input client rather than a field's, so the platform is
    // told directly as well as through the focus node.
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void _reconcile() {
    if (!_released) return;
    _released = false;
    // After the frame: focus settles first, so a field that comes back autofocused is read
    // as asking for the keyboard rather than as an inset nobody claimed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _typing) return;
      if (View.of(context).viewInsets.bottom <= 0) return;
      // Whether a keyboard is really under it or the number is a leftover, the same call is
      // the answer to both.
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    });
    // A post-frame callback waits for a frame, and an app resumed onto a still screen may
    // not draw one for a while.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// A scope with the primary focus is the shape of "no field has it": scopes are what
  /// focus falls back to, and none of them opens an input connection.
  bool get _typing {
    final focus = FocusManager.instance.primaryFocus;
    return focus != null && focus is! FocusScopeNode;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

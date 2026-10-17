import 'package:striked/platform/shell/shell_connection.dart';

UserIntent testIntent() {
  late final UserIntent minted;
  UserIntent.onGesture((intent) => minted = intent)();
  return minted;
}

PlatformSignal testSignal() {
  late final PlatformSignal minted;
  PlatformSignal.onNetwork((signal, _) => minted = signal)(true);
  return minted;
}

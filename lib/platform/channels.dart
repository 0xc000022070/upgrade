/// Platform channel names. The Kotlin side registers the same strings, so a value change
/// here needs the matching change in `android/app/src/main/kotlin`.
abstract final class Channels {
  static const _root = 'dev.luisnquin.upgrade';

  static const browser = '$_root/browser';
  static const device = '$_root/device';
  static const deviceNetwork = '$_root/device/network';
  static const deviceThrottle = '$_root/device/throttle';
  static const files = '$_root/files';
  static const launcher = '$_root/launcher';
  static const linux = '$_root/linux';
  static const linuxState = '$_root/linux/state';
  static const pip = '$_root/pip';
  static const pipMode = '$_root/pip/mode';
  static const speech = '$_root/speech';
}

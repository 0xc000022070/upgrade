package dev.luisnquin.upgrade

/** Mirror of lib/platform/channels.dart: the same names, registered here and cleared in one place. */
object Channels {
    private const val ROOT = "dev.luisnquin.upgrade"

    const val BROWSER = "$ROOT/browser"
    const val DEVICE = "$ROOT/device"
    const val DEVICE_NETWORK = "$ROOT/device/network"
    const val DEVICE_THROTTLE = "$ROOT/device/throttle"
    const val FILES = "$ROOT/files"
    const val LAUNCHER = "$ROOT/launcher"
    const val LINUX = "$ROOT/linux"
    const val LINUX_STATE = "$ROOT/linux/state"
    const val PIP = "$ROOT/pip"
    const val PIP_MODE = "$ROOT/pip/mode"
    const val SPEECH = "$ROOT/speech"
}

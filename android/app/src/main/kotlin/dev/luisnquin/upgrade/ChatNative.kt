package dev.luisnquin.upgrade

import android.content.Context

internal object ChatNative {
    private var ready = false

    @JvmStatic private external fun setup(context: Context)

    @Synchronized
    fun prepare(context: Context): String {
        if (!ready) {
            System.loadLibrary("upgrade_chat")
            setup(context.applicationContext)
            ready = true
        }
        return context.filesDir.resolve("chat").apply { mkdirs() }.path
    }
}

package dev.luisnquin.upgrade

import android.content.Context
import androidx.core.content.ContextCompat
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object BrowserProxy {
    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "proxy") return result.notImplemented()
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            return result.error("unsupported", "this WebView cannot be given a proxy", null)
        }
        val executor = ContextCompat.getMainExecutor(context)
        val done = Runnable { result.success(null) }
        val port = call.argument<Int>("port")
        val controller = ProxyController.getInstance()
        if (port == null) return controller.clearProxyOverride(executor, done)
        // Chromium bypasses loopback names by default; here localhost means the host's.
        val config = ProxyConfig.Builder()
            .addProxyRule("socks://127.0.0.1:$port")
            .removeImplicitRules()
            .build()
        controller.setProxyOverride(config, executor, done)
    }
}

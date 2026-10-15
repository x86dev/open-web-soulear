package io.github.openearcam.openearcam

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The camera Wi-Fi has no internet - Android would then route connections over
 * mobile data, and the camera (192.168.1.1) would be unreachable. That is why
 * the whole app is bound to the Wi-Fi before connecting (the original app does
 * the same, WifiCallBackFuc.bindSocket).
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "soulear/network").setMethodCallHandler { call, result ->
            val cm = getSystemService(ConnectivityManager::class.java)
            when (call.method) {
                "bindToWifi" -> {
                    @Suppress("DEPRECATION")
                    val wifi = cm.allNetworks.firstOrNull {
                        cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                    }
                    result.success(wifi != null && cm.bindProcessToNetwork(wifi))
                }
                "unbind" -> result.success(cm.bindProcessToNetwork(null))
                else -> result.notImplemented()
            }
        }
    }
}

package com.interactpak.interact_talk

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(VirtualBgPlugin())
        // Phone B / OTA: Dart picks armeabi-v7a vs arm64 APK URL from latest.json.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.interactpak.interact_talk/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "primaryAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
                "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                else -> result.notImplemented()
            }
        }
    }
}

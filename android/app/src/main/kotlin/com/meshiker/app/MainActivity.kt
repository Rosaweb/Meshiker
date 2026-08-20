package com.meshiker.app

import android.graphics.Rect
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val gestureExclusionChannel = "meshiker/system_gestures"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, gestureExclusionChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "setExclusionRects") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    @Suppress("UNCHECKED_CAST")
                    val rectsArg = call.arguments as? List<Map<String, Int>> ?: emptyList()
                    val rects = rectsArg.map { r ->
                        Rect(r["left"] ?: 0, r["top"] ?: 0, r["right"] ?: 0, r["bottom"] ?: 0)
                    }
                    window.decorView.post {
                        window.decorView.systemGestureExclusionRects = rects
                    }
                }
                result.success(null)
            }
    }
}

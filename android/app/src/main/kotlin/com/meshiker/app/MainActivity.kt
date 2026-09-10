package com.meshiker.app

import android.content.Intent
import android.graphics.Rect
import android.media.MediaScannerConnection
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// RevenueCatUI.presentPaywall() nécessite que MainActivity hérite de
// FlutterFragmentActivity (paywall natif rendu comme Fragment) — sinon
// PlatformException(PAYWALLS_MISSING_WRONG_ACTIVITY) au premier appel.
class MainActivity : FlutterFragmentActivity() {
    private val gestureExclusionChannel = "meshiker/system_gestures"
    private val photoCaptureChannel = "meshiker/photo_capture"

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

        // Photos géolocalisées (spec-photos-geolocalisees.md §3.2/§3.3).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, photoCaptureChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Lance l'appli caméra PAR DÉFAUT via son intent de lancement
                    // propre (STILL_IMAGE_CAMERA), pas startActivityForResult : on
                    // obtient l'interface caméra complète (réglages pro, rafale),
                    // et l'utilisateur peut enchaîner plusieurs clichés. Les
                    // photos sont détectées côté Dart par l'observateur de
                    // pellicule (photo_manager), pas par un retour d'activité.
                    "launchCamera" -> {
                        val intent = Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        if (intent.resolveActivity(packageManager) != null) {
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    // (Ré)indexe un fichier dans le MediaStore pour qu'il
                    // apparaisse tout de suite dans la galerie système.
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("no_path", "path manquant", null)
                        } else {
                            MediaScannerConnection.scanFile(
                                applicationContext, arrayOf(path), null
                            ) { _, _ -> }
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

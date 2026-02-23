package com.termopus.app

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import com.termopus.app.bridge.SecurityChannel

/**
 * Main activity for Claude Code Remote.
 *
 * Extends [FlutterFragmentActivity] (not plain FlutterActivity) so that
 * [androidx.biometric.BiometricPrompt] can obtain a FragmentManager.
 *
 * The only responsibility here is to register the native [SecurityChannel]
 * plugin that bridges Dart ↔ Kotlin for all security, crypto, and network
 * operations.
 */
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(SecurityChannel())
    }
}

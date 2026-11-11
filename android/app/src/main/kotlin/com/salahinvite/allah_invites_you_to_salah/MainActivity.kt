package com.salahinvite.allah_invites_you_to_salah

import com.salahinvite.allah_invites_you_to_salah.guard.AppGuardPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AppGuardPlugin())
        flutterEngine.plugins.add(IncomingCallPlugin())
    }
}

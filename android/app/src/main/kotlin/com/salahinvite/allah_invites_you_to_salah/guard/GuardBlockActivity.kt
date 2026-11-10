package com.salahinvite.allah_invites_you_to_salah.guard

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Full-screen "Allah is calling" guard screen, launched by
 * [AppGuardForegroundService] over a guarded app opened during the
 * 15-minute window after a prayer enters.
 *
 * Runs its OWN Flutter engine (entrypoint `guardMain`, see
 * `lib/guard_main.dart`) — not the app's main engine — so it never depends
 * on the main app having been launched, and stays fast by reusing a
 * pre-warmed cached engine when [AppGuardForegroundService] had time to
 * prepare one.
 */
class GuardBlockActivity : FlutterActivity() {
    companion object {
        const val ENGINE_ID = "guard_engine"
        const val EXTRA_PRAYER = "prayer"
        const val EXTRA_BLOCKED_PACKAGE = "blocked_package"
        const val CHANNEL = "com.salahinvite.allah_invites_you_to_salah/app_guard_screen"

        fun start(context: Context, prayer: String, blockedPackage: String) {
            val intent = Intent(context, GuardBlockActivity::class.java).apply {
                putExtra(EXTRA_PRAYER, prayer)
                putExtra(EXTRA_BLOCKED_PACKAGE, blockedPackage)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            context.startActivity(intent)
        }

        /**
         * Pre-warms the guard Flutter engine so [start] above is fast when a
         * guarded app is actually detected. Safe to call repeatedly — it is
         * a no-op once the engine is already cached.
         */
        fun prewarm(context: Context) {
            if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) return
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                if (!loader.initialized()) {
                    loader.startInitialization(context.applicationContext)
                    loader.ensureInitializationComplete(context.applicationContext, null)
                }
                val engine = FlutterEngine(context.applicationContext)
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault().let {
                        DartExecutor.DartEntrypoint(it.pathToBundle, "guardMain")
                    }
                )
                FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            } catch (_: Exception) {
                // Best-effort only: GuardBlockActivity falls back to creating
                // its own engine on demand (see getCachedEngineId/
                // getDartEntrypointFunctionName below) if this failed.
            }
        }
    }

    private var methodChannel: MethodChannel? = null

    // Only reuse the cache if it is actually warm; otherwise fall back to a
    // fresh engine using the same entrypoint (see getDartEntrypointFunctionName).
    override fun getCachedEngineId(): String? =
        if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) ENGINE_ID else null

    override fun getDartEntrypointFunctionName(): String = "guardMain"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val prayer = intent.getStringExtra(EXTRA_PRAYER) ?: "Prayer"
        val blockedPackage = intent.getStringExtra(EXTRA_BLOCKED_PACKAGE) ?: ""
        val blockedAppLabel = try {
            val pm = packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(blockedPackage, 0)).toString()
        } catch (_: Exception) {
            "This app"
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getConfig" -> result.success(
                    mapOf(
                        "prayer" to prayer,
                        "blockedPackage" to blockedPackage,
                        "blockedAppLabel" to blockedAppLabel,
                    )
                )
                "answer" -> {
                    goHome()
                    finishAndRemoveTask()
                    result.success(null)
                }
                "decline" -> {
                    AppGuardForegroundService.exemptPackageForCurrentWindow(blockedPackage)
                    finishAndRemoveTask()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Tell the already-running cached engine which prayer/app to show —
        // its UI may already be built from a previous window.
        channel.invokeMethod(
            "configure",
            mapOf(
                "prayer" to prayer,
                "blockedPackage" to blockedPackage,
                "blockedAppLabel" to blockedAppLabel,
            ),
        )
    }

    private fun goHome() {
        val home = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(home)
    }

    override fun onBackPressed() {
        // Never allow backing out into the guarded app without a choice —
        // mirrors the main app's incoming-call screen, which only exits via
        // Answer/Decline.
    }

    override fun onDestroy() {
        methodChannel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}

package com.salahinvite.allah_invites_you_to_salah.guard

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView
import com.salahinvite.allah_invites_you_to_salah.R

/**
 * Full-screen "Allah is calling" guard screen, launched by
 * [AppGuardForegroundService] over a guarded app opened during the
 * 15-minute window after a prayer enters.
 *
 * Native Android layout (not a Flutter Activity). A second Flutter engine
 * started from the foreground service previously painted only the window
 * background (solid green) and never the Dart UI on some devices — so this
 * screen is XML + Activity for reliability.
 */
class GuardBlockActivity : Activity() {
    companion object {
        const val EXTRA_PRAYER = "prayer"
        const val EXTRA_BLOCKED_PACKAGE = "blocked_package"

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
         * Kept as a no-op so the foreground service can still call it after
         * the Flutter-engine prewarm was removed. Harmless.
         */
        fun prewarm(@Suppress("UNUSED_PARAMETER") context: Context) {
            // No Flutter engine to warm anymore.
        }
    }

    private var blockedPackage: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep visible over lock screen / while screen is off briefly.
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
        )
        setContentView(R.layout.activity_guard_block)

        val prayerRaw = intent.getStringExtra(EXTRA_PRAYER)?.trim().orEmpty()
        blockedPackage = intent.getStringExtra(EXTRA_BLOCKED_PACKAGE).orEmpty()
        val blockedAppLabel = try {
            val pm = packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(blockedPackage, 0)).toString()
        } catch (_: Exception) {
            "This app"
        }

        // Demo windows pass "Test" — show a neutral label instead.
        val prayerLabel = when {
            prayerRaw.isEmpty() -> "Prayer"
            prayerRaw.equals("Test", ignoreCase = true) -> "Prayer"
            else -> prayerRaw
        }

        findViewById<TextView>(R.id.guard_prayer_name).text = prayerLabel.uppercase()
        findViewById<TextView>(R.id.guard_subtitle).text =
            "$blockedAppLabel will stay closed until you answer or decline."

        findViewById<ImageButton>(R.id.guard_decline).setOnClickListener {
            AppGuardForegroundService.exemptPackageForCurrentWindow(blockedPackage)
            finishAndRemoveTask()
        }
        findViewById<ImageButton>(R.id.guard_answer).setOnClickListener {
            goHome()
            finishAndRemoveTask()
        }

        // Rotate the decline icon 135° so it reads as "hang up" rather than
        // a normal call icon (same glyph as Answer).
        findViewById<ImageButton>(R.id.guard_decline).rotation = 135f
    }

    private fun goHome() {
        val home = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(home)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Never allow backing out into the guarded app without a choice.
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Re-bind labels if the service relaunches us for a different app
        // during the same window.
        recreate()
    }
}

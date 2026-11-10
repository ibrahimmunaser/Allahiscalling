package com.salahinvite.allah_invites_you_to_salah.guard

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView
import com.salahinvite.allah_invites_you_to_salah.R
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Full-screen "Allah is calling" guard screen, launched by
 * [AppGuardForegroundService] over a guarded app opened during the
 * 15-minute window after a prayer enters.
 *
 * Native Android layout (not a Flutter Activity). A second Flutter engine
 * started from the foreground service previously painted only the window
 * background (solid green) and never the Dart UI on some devices — so this
 * screen is XML + Activity for reliability.
 *
 * Answer / Decline stay locked until five ring vibrates finish, so the user
 * has to sit with the call before choosing.
 */
class GuardBlockActivity : Activity() {
    companion object {
        const val EXTRA_PRAYER = "prayer"
        const val EXTRA_BLOCKED_PACKAGE = "blocked_package"
        const val EXTRA_END_AT = "end_at_millis"

        private const val REQUIRED_RING_VIBRATES = 5
        /** One double-buzz "ring" (on-off-on), then a pause before the next. */
        private const val RING_PATTERN_MS = 680L
        private const val RING_GAP_MS = 700L

        fun start(
            context: Context,
            prayer: String,
            blockedPackage: String,
            endAtMillis: Long,
        ) {
            val intent = Intent(context, GuardBlockActivity::class.java).apply {
                putExtra(EXTRA_PRAYER, prayer)
                putExtra(EXTRA_BLOCKED_PACKAGE, blockedPackage)
                putExtra(EXTRA_END_AT, endAtMillis)
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

        fun formatRemaining(remainingMs: Long): String {
            val clamped = remainingMs.coerceAtLeast(0L)
            val totalSeconds = TimeUnit.MILLISECONDS.toSeconds(clamped)
            val minutes = totalSeconds / 60
            val seconds = totalSeconds % 60
            return String.format(Locale.US, "%d:%02d", minutes, seconds)
        }
    }

    private var blockedPackage: String = ""
    private var endAtMillis: Long = 0L
    private val handler = Handler(Looper.getMainLooper())
    private var countdownRunnable: Runnable? = null
    private var ringRunnable: Runnable? = null
    private var ringsCompleted = 0
    private var actionsUnlocked = false
    private var ringsStarted = false

    private lateinit var countdownView: TextView
    private lateinit var actionsHint: TextView
    private lateinit var declineButton: ImageButton
    private lateinit var answerButton: ImageButton

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

        countdownView = findViewById(R.id.guard_countdown)
        actionsHint = findViewById(R.id.guard_actions_hint)
        declineButton = findViewById(R.id.guard_decline)
        answerButton = findViewById(R.id.guard_answer)

        // Rotate the decline icon 135° so it reads as "hang up" rather than
        // a normal call icon (same glyph as Answer).
        declineButton.rotation = 135f

        declineButton.setOnClickListener {
            if (!actionsUnlocked) return@setOnClickListener
            AppGuardForegroundService.exemptPackageForCurrentWindow(blockedPackage)
            finishAndRemoveTask()
        }
        answerButton.setOnClickListener {
            if (!actionsUnlocked) return@setOnClickListener
            goHome()
            finishAndRemoveTask()
        }

        bindFromIntent(intent)
        lockActionsUntilRings()
        // Vibration starts in onResume once the window is focused — buzzing
        // from onCreate was a silent no-op on several OEM builds.
    }

    override fun onResume() {
        super.onResume()
        if (!ringsStarted && !actionsUnlocked) {
            ringsStarted = true
            startRingVibrates()
        }
    }

    private fun bindFromIntent(intent: Intent) {
        val prayerRaw = intent.getStringExtra(EXTRA_PRAYER)?.trim().orEmpty()
        blockedPackage = intent.getStringExtra(EXTRA_BLOCKED_PACKAGE).orEmpty()
        endAtMillis = intent.getLongExtra(EXTRA_END_AT, 0L)

        // Demo windows pass "Test" — show a neutral label instead.
        val prayerLabel = when {
            prayerRaw.isEmpty() -> "Prayer"
            prayerRaw.equals("Test", ignoreCase = true) -> "Prayer"
            else -> prayerRaw
        }

        findViewById<TextView>(R.id.guard_prayer_name).text = prayerLabel.uppercase(Locale.US)
        findViewById<TextView>(R.id.guard_headline).text =
            "Your apps have been blocked.\nGet up and pray."
        findViewById<TextView>(R.id.guard_unlock_label).text = "Your apps unlock in"
        startCountdown()
    }

    private fun lockActionsUntilRings() {
        actionsUnlocked = false
        ringsCompleted = 0
        ringsStarted = false
        declineButton.isEnabled = false
        answerButton.isEnabled = false
        declineButton.alpha = 0.35f
        answerButton.alpha = 0.35f
        updateRingHint()
    }

    private fun unlockActions() {
        actionsUnlocked = true
        declineButton.isEnabled = true
        answerButton.isEnabled = true
        declineButton.alpha = 1f
        answerButton.alpha = 1f
        actionsHint.text = "Answer to go pray — or Decline to keep this app for now"
    }

    private fun updateRingHint() {
        actionsHint.text =
            "Feel the call — $ringsCompleted / $REQUIRED_RING_VIBRATES before you can choose"
    }

    private fun startRingVibrates() {
        ringRunnable?.let { handler.removeCallbacks(it) }
        val tick = object : Runnable {
            override fun run() {
                if (isFinishing) return
                vibrateOnce()
                ringsCompleted += 1
                updateRingHint()
                if (ringsCompleted >= REQUIRED_RING_VIBRATES) {
                    unlockActions()
                    return
                }
                handler.postDelayed(this, RING_PATTERN_MS + RING_GAP_MS)
            }
        }
        ringRunnable = tick
        tick.run()
    }

    /**
     * Phone-style double buzz tagged as a ringtone/alarm so OEMs don't
     * swallow a plain one-shot (common when launched over another app).
     * Also fires a view haptic as a second path.
     */
    private fun vibrateOnce() {
        @Suppress("DEPRECATION")
        window.decorView.performHapticFeedback(
            HapticFeedbackConstants.LONG_PRESS,
            HapticFeedbackConstants.FLAG_IGNORE_GLOBAL_SETTING or
                HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING,
        )

        val vibrator = vibratorOrNull() ?: return
        if (!vibrator.hasVibrator()) return

        // Double pulse: buzz — gap — buzz (like a ringing phone).
        val timings = longArrayOf(0, 280, 120, 280)
        val amplitudes = intArrayOf(0, 255, 0, 255)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (vibrator.hasAmplitudeControl()) {
                VibrationEffect.createWaveform(timings, amplitudes, -1)
            } else {
                VibrationEffect.createWaveform(timings, -1)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                vibrator.vibrate(
                    effect,
                    VibrationAttributes.Builder()
                        .setUsage(VibrationAttributes.USAGE_RINGTONE)
                        .build(),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(
                    effect,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
            }
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(timings, -1)
        }
    }

    private fun vibratorOrNull(): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(VibratorManager::class.java) ?: return null
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private fun startCountdown() {
        countdownRunnable?.let { handler.removeCallbacks(it) }
        val tick = object : Runnable {
            override fun run() {
                val remaining = endAtMillis - System.currentTimeMillis()
                if (remaining <= 0L) {
                    countdownView.text = "0:00"
                    finishAndRemoveTask()
                    return
                }
                countdownView.text = formatRemaining(remaining)
                handler.postDelayed(this, 1_000L)
            }
        }
        countdownRunnable = tick
        tick.run()
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
        bindFromIntent(intent)
        // Fresh blocked-app launch: reset the five-ring gate.
        ringRunnable?.let { handler.removeCallbacks(it) }
        lockActionsUntilRings()
        ringsStarted = true
        startRingVibrates()
    }

    override fun onDestroy() {
        ringRunnable?.let { handler.removeCallbacks(it) }
        ringRunnable = null
        countdownRunnable?.let { handler.removeCallbacks(it) }
        countdownRunnable = null
        vibratorOrNull()?.cancel()
        super.onDestroy()
    }
}

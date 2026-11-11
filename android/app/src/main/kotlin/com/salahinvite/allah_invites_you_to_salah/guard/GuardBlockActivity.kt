package com.salahinvite.allah_invites_you_to_salah.guard

import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.LayerDrawable
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
import android.view.animation.LinearInterpolator
import android.widget.ImageButton
import android.widget.ImageView
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
    private lateinit var heroView: ImageView
    private var heroAnimator: ValueAnimator? = null

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
        heroView = findViewById(R.id.guard_hero)

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
        applyPrayerCallLook(prayerRaw)
        startCountdown()
    }

    /**
     * Same illustrated scene and bottom glow as the incoming prayer call.
     * Copy on this screen is unchanged — only the backdrop and buttons.
     */
    private fun applyPrayerCallLook(prayerRaw: String) {
        val look = lookFor(prayerRaw)
        val panelBottom = lerpColor(look.gradientBottom, look.accent, 0.5f)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = panelBottom

        findViewById<TextView>(R.id.guard_prayer_name).setTextColor(look.softAccent)
        countdownView.setTextColor(look.softAccent)

        // The artwork has its own title baked in ("PRAYER TIME" sits about
        // 27% down once the image is cropped). Keep the arch at the top and
        // the bottom glow, and go fully opaque before that baked line so
        // only this screen's wording is readable.
        // Evenly spaced stops cover the baked title on every API level.
        // On Android 10+ the same curve is placed exactly.
        val deep = look.deep
        val scrimColors = intArrayOf(
            Color.TRANSPARENT,
            withAlpha(deep, 0x33),
            deep,
            deep,
            deep,
            deep,
            deep,
            look.gradientBottom,
            lerpColor(look.gradientBottom, panelBottom, 0.5f),
            panelBottom,
            panelBottom,
        )
        val scrim = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, scrimColors)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            scrim.setColors(
                intArrayOf(
                    Color.TRANSPARENT,
                    withAlpha(deep, 0x33),
                    deep,
                    look.gradientBottom,
                    panelBottom,
                ),
                floatArrayOf(0f, 0.10f, 0.18f, 0.62f, 1f),
            )
        }
        findViewById<android.view.View>(R.id.guard_scrim).background = scrim

        val glow = findViewById<android.view.View>(R.id.guard_glow)
        glow.post {
            val radial = GradientDrawable().apply {
                gradientType = GradientDrawable.RADIAL_GRADIENT
                shape = GradientDrawable.RECTANGLE
                gradientRadius = glow.width.coerceAtLeast(1) * 0.72f
                setGradientCenter(0.5f, 1.05f)
                colors = intArrayOf(withAlpha(look.accent, 0xB0), Color.TRANSPARENT)
            }
            glow.background = radial
        }

        declineButton.background = callButtonBackground(
            intArrayOf(0xFFE23E3E.toInt(), 0xFFE23E3E.toInt()),
            0xFFE23E3E.toInt(),
        )
        answerButton.background = callButtonBackground(
            intArrayOf(look.softAccent, look.accent),
            Color.WHITE,
        )
        answerButton.setColorFilter(look.onAccent)

        loadHero(prayerRaw)
    }

    private fun loadHero(prayerRaw: String) {
        val file = when (prayerRaw.lowercase(Locale.US)) {
            "fajr" -> "fajr.jpg"
            "dhuhr" -> "dhuhr.jpg"
            "asr" -> "asr.jpg"
            "maghrib" -> "maghrib.jpg"
            "isha" -> "isha.jpg"
            else -> "maghrib.jpg"
        }
        val bitmap = try {
            assets.open("flutter_assets/assets/incoming_call/$file").use { stream ->
                BitmapFactory.decodeStream(stream)
            }
        } catch (_: Exception) {
            null
        } ?: return
        heroView.setImageBitmap(bitmap)
        heroView.post { positionHero() }
    }

    /** Top-align the artwork and scale it so the baked-in button row sits off screen. */
    private fun positionHero() {
        val drawable = heroView.drawable ?: return
        val bw = drawable.intrinsicWidth.toFloat()
        val bh = drawable.intrinsicHeight.toFloat()
        val vw = heroView.width.toFloat()
        val vh = heroView.height.toFloat()
        if (bw <= 0f || bh <= 0f || vw <= 0f || vh <= 0f) return
        val scale = (vh / 0.74f) / bh
        val dx = (vw - bw * scale) / 2f
        heroView.imageMatrix = Matrix().apply {
            setScale(scale, scale)
            postTranslate(dx, 0f)
        }
        heroAnimator?.cancel()
        heroAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 9000L
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { animator ->
                val t = animator.animatedFraction
                val eased = t * t * (3f - 2f * t)
                val s = scale * (1f + 0.045f * eased)
                val shift = (vw - bw * s) / 2f
                heroView.imageMatrix = Matrix().apply {
                    setScale(s, s)
                    postTranslate(shift, 0f)
                }
            }
            start()
        }
    }

    /**
     * 108dp hit target: a soft halo, then an 82dp circle inset inside it,
     * matching the incoming-call buttons. The halo is what keeps the
     * Answer circle readable on a panel that uses the same warm color.
     */
    private fun callButtonBackground(fillColors: IntArray, haloColor: Int): Drawable {
        val halo = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            gradientType = GradientDrawable.RADIAL_GRADIENT
            gradientRadius = dp(54f).toFloat()
            setGradientCenter(0.5f, 0.5f)
            colors = intArrayOf(withAlpha(haloColor, 0x66), withAlpha(haloColor, 0))
        }
        val fill = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            orientation = GradientDrawable.Orientation.TL_BR
            colors = fillColors
            setStroke(dp(1.5f), Color.argb(0xB3, 255, 255, 255))
        }
        return LayerDrawable(arrayOf(halo, InsetDrawable(fill, dp(13f))))
    }

    private fun dp(value: Float): Int =
        (value * resources.displayMetrics.density).toInt().coerceAtLeast(1)

    private data class PrayerLook(
        val deep: Int,
        val accent: Int,
        val softAccent: Int,
        val gradientBottom: Int,
        val onAccent: Int,
    )

    private fun lookFor(prayerRaw: String): PrayerLook {
        return when (prayerRaw.lowercase(Locale.US)) {
            "fajr" -> PrayerLook(0xFF1B2838.toInt(), 0xFF8EACCB.toInt(), 0xFFC5D5E8.toInt(), 0xFF243B55.toInt(), 0xFF0B1220.toInt())
            "dhuhr" -> PrayerLook(0xFF0C4A56.toInt(), 0xFFE8B84A.toInt(), 0xFFF5D98A.toInt(), 0xFF187A8A.toInt(), 0xFF063640.toInt())
            "asr" -> PrayerLook(0xFF4A3218.toInt(), 0xFFD4A04A.toInt(), 0xFFE8C98A.toInt(), 0xFF6B4820.toInt(), 0xFF1A140C.toInt())
            "maghrib" -> PrayerLook(0xFF3D1518.toInt(), 0xFFE08A5A.toInt(), 0xFFF0B898.toInt(), 0xFF6B2A28.toInt(), 0xFF14080A.toInt())
            "isha" -> PrayerLook(0xFF0C1428.toInt(), 0xFFA8B8D8.toInt(), 0xFFD0DAEC.toInt(), 0xFF1A2848.toInt(), 0xFF050810.toInt())
            // Demo windows pass "Test". Same sunset scene as the fallback
            // artwork, while the label stays the neutral "Prayer".
            else -> PrayerLook(0xFF3D1518.toInt(), 0xFFE08A5A.toInt(), 0xFFF0B898.toInt(), 0xFF6B2A28.toInt(), 0xFF14080A.toInt())
        }
    }

    private fun lerpColor(start: Int, end: Int, amount: Float): Int {
        val t = amount.coerceIn(0f, 1f)
        val inv = 1f - t
        return Color.argb(
            (Color.alpha(start) * inv + Color.alpha(end) * t).toInt(),
            (Color.red(start) * inv + Color.red(end) * t).toInt(),
            (Color.green(start) * inv + Color.green(end) * t).toInt(),
            (Color.blue(start) * inv + Color.blue(end) * t).toInt(),
        )
    }

    private fun withAlpha(color: Int, alpha: Int): Int =
        Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))

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
     * Phone-style double buzz. Tagged as an ALARM, not a ringtone — a
     * ringtone-category vibration is silenced by Do Not Disturb / "Vibrate"
     * ring-mode settings (confirmed the actual cause of the silent block
     * screen: zen_mode was active), while alarm-category vibration is
     * designed to bypass exactly that, the same way an alarm clock still
     * buzzes on a silenced phone. Also fires a view haptic as a second path.
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
                        .setUsage(VibrationAttributes.USAGE_ALARM)
                        .build(),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(
                    effect,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
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
        heroAnimator?.cancel()
        heroAnimator = null
        ringRunnable?.let { handler.removeCallbacks(it) }
        ringRunnable = null
        countdownRunnable?.let { handler.removeCallbacks(it) }
        countdownRunnable = null
        vibratorOrNull()?.cancel()
        super.onDestroy()
    }
}

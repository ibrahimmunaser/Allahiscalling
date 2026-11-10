package com.salahinvite.allah_invites_you_to_salah.guard

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.salahinvite.allah_invites_you_to_salah.MainActivity
import com.salahinvite.allah_invites_you_to_salah.R

/**
 * Watches the foreground app for the 15 minutes after a prayer enters, and
 * covers any app the user chose to guard with [GuardBlockActivity]'s
 * "Allah is calling" screen the moment it is opened.
 *
 * Requires two user-granted special permissions (checked before this is
 * ever started — see AppGuardPlugin): PACKAGE_USAGE_STATS (to see which app
 * is in the foreground) and "Display over other apps" / SYSTEM_ALERT_WINDOW
 * (so launching an activity from a background service is not blocked by
 * Android 10+'s background-activity-start restriction).
 */
class AppGuardForegroundService : Service() {

    companion object {
        const val EXTRA_PRAYER = "prayer"
        const val EXTRA_END_AT = "end_at_millis"
        const val EXTRA_WINDOW_ID = "window_id"

        private const val NOTIFICATION_CHANNEL_ID = "app_guard_service"
        private const val NOTIFICATION_ID = 9001
        private const val POLL_INTERVAL_MS = 1200L

        @Volatile
        private var currentInstance: AppGuardForegroundService? = null

        /**
         * Exempts [packageName] from being re-blocked for the remainder of
         * the currently active guard window (the "Decline" behavior — this
         * one app is left alone for now; everything else, and this app
         * again after the next prayer, stays guarded).
         */
        fun exemptPackageForCurrentWindow(packageName: String) {
            currentInstance?.exemptedThisWindow?.add(packageName)
            currentInstance?.blockScreenShowingFor = null
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var pollRunnable: Runnable? = null
    private var stopRunnable: Runnable? = null
    private val exemptedThisWindow = mutableSetOf<String>()
    private var windowEndAtMillis: Long = 0L
    private var currentPrayer: String = "Prayer"

    /** The guarded package the block screen is currently (believed to be) showing for. */
    @Volatile
    private var blockScreenShowingFor: String? = null

    override fun onCreate() {
        super.onCreate()
        currentInstance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prayer = intent?.getStringExtra(EXTRA_PRAYER) ?: "Prayer"
        val endAt = intent?.getLongExtra(EXTRA_END_AT, 0L) ?: 0L
        val windowId = intent?.getIntExtra(EXTRA_WINDOW_ID, -1) ?: -1
        val remaining = endAt - System.currentTimeMillis()

        if (!GuardPrefs.isEnabled(this) || remaining <= 0) {
            GuardPrefs.removePendingWindow(this, windowId)
            stopSelf()
            return START_NOT_STICKY
        }

        exemptedThisWindow.clear()
        blockScreenShowingFor = null
        windowEndAtMillis = endAt
        currentPrayer = prayer

        startForeground(NOTIFICATION_ID, buildNotification(prayer))
        GuardBlockActivity.prewarm(this)

        stopRunnable?.let { handler.removeCallbacks(it) }
        val stop = Runnable {
            GuardPrefs.removePendingWindow(this, windowId)
            stopSelf()
        }
        stopRunnable = stop
        handler.postDelayed(stop, remaining)

        startPolling()
        return START_NOT_STICKY
    }

    private fun startPolling() {
        pollRunnable?.let { handler.removeCallbacks(it) }
        val ownPackage = packageName
        lateinit var runnable: Runnable
        runnable = Runnable {
            try {
                checkForegroundApp(ownPackage)
            } catch (_: Exception) {
                // A single failed poll (e.g. a transient AppOps hiccup) must
                // never stop the whole 15-minute watch.
            }
            handler.postDelayed(runnable, POLL_INTERVAL_MS)
        }
        pollRunnable = runnable
        handler.post(runnable)
    }

    private fun checkForegroundApp(ownPackage: String) {
        val guarded = GuardPrefs.guardedPackages(this)
        if (guarded.isEmpty()) return

        val fg = currentForegroundPackage() ?: return

        if (fg != blockScreenShowingFor) {
            // The foreground app changed since we last showed the block
            // screen (or we never showed one) — a fresh guarded-app launch
            // is detectable again.
            if (fg == ownPackage) {
                blockScreenShowingFor = null
                return
            }
        }

        if (fg !in guarded) return
        if (fg in exemptedThisWindow) return
        if (fg == blockScreenShowingFor) return // already covering it

        blockScreenShowingFor = fg
        GuardBlockActivity.start(this, currentPrayer, fg, windowEndAtMillis)
    }

    /**
     * Most recent app brought to the foreground, from the last ~8 seconds
     * of usage events. Requires the PACKAGE_USAGE_STATS special permission.
     */
    private fun currentForegroundPackage(): String? {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager ?: return null
        val end = System.currentTimeMillis()
        val begin = end - 8_000
        val events = usm.queryEvents(begin, end)
        val event = UsageEvents.Event()
        var latestPackage: String? = null
        var latestTime = 0L
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val isForegroundEvent = event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    event.eventType == UsageEvents.Event.ACTIVITY_RESUMED)
            if (isForegroundEvent && event.timeStamp >= latestTime) {
                latestTime = event.timeStamp
                latestPackage = event.packageName
            }
        }
        return latestPackage
    }

    private fun buildNotification(prayer: String) = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
        .setContentTitle("Guarding your $prayer prayer time")
        .setContentText("Apps you chose will show \"Allah is calling\" for the next few minutes.")
        .setSmallIcon(applicationInfo.icon.let { if (it != 0) it else R.mipmap.ic_launcher })
        .setOngoing(true)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setContentIntent(
            android.app.PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                android.app.PendingIntent.FLAG_IMMUTABLE,
            )
        )
        .build()

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "App Guard",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows while apps you chose are guarded during a prayer window."
            }
        )
    }

    override fun onDestroy() {
        pollRunnable?.let { handler.removeCallbacks(it) }
        stopRunnable?.let { handler.removeCallbacks(it) }
        if (currentInstance == this) currentInstance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

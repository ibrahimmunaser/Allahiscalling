package com.salahinvite.allah_invites_you_to_salah.guard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires at the exact moment a prayer enters (scheduled by [AppGuardPlugin]
 * alongside the ordinary prayer notification/AlarmKit alert) and starts the
 * 15-minute [AppGuardForegroundService] window.
 *
 * Reads enabled/guarded-packages fresh from [GuardPrefs] at fire time, so a
 * setting the user changed after scheduling is always honored.
 */
class GuardWindowAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val windowId = intent.getIntExtra(AppGuardForegroundService.EXTRA_WINDOW_ID, -1)
        val prayer = intent.getStringExtra(AppGuardForegroundService.EXTRA_PRAYER) ?: "Prayer"
        GuardPrefs.removePendingWindow(context, windowId)

        if (!GuardPrefs.isEnabled(context) || GuardPrefs.guardedPackages(context).isEmpty()) {
            return
        }

        val endAt = System.currentTimeMillis() + GuardScheduling.WINDOW_DURATION_MS
        val serviceIntent = Intent(context, AppGuardForegroundService::class.java).apply {
            putExtra(AppGuardForegroundService.EXTRA_PRAYER, prayer)
            putExtra(AppGuardForegroundService.EXTRA_END_AT, endAt)
            putExtra(AppGuardForegroundService.EXTRA_WINDOW_ID, windowId)
        }
        androidx.core.content.ContextCompat.startForegroundService(context, serviceIntent)
    }
}

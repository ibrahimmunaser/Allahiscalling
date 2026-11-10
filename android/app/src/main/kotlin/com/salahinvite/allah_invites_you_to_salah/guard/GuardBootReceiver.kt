package com.salahinvite.allah_invites_you_to_salah.guard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms any still-future guard window after a reboot or app update, since
 * raw [android.app.AlarmManager] alarms (unlike flutter_local_notifications'
 * own, which that plugin re-persists itself) do not survive either.
 * Mirrors `ScheduledNotificationBootReceiver`'s purpose for the guard
 * feature.
 */
class GuardBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val now = System.currentTimeMillis()
        GuardPrefs.pendingWindows(context).forEach { window ->
            if (window.triggerAtMillis > now) {
                GuardScheduling.schedule(context, window.id, window.prayer, window.triggerAtMillis)
            } else {
                GuardPrefs.removePendingWindow(context, window.id)
            }
        }
    }
}

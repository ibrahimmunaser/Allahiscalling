package com.salahinvite.allah_invites_you_to_salah

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings

/**
 * Fires at the exact moment a prayer enters, scheduled alongside the
 * ordinary call-style notification (see `LocalNotificationService`,
 * Android branch, and `IncomingCallScheduling`).
 *
 * The notification's own `fullScreenIntent` only auto-presents while the
 * device is locked/screen-off — while unlocked and in another app, Android
 * downgrades it to a heads-up banner the user must tap. This receiver
 * closes that gap: when "Display over other apps" is granted (the same
 * permission App Guard uses), it force-launches the app directly, the same
 * way [AppGuardForegroundService]'s guard.GuardBlockActivity does.
 *
 * Always records the pending prayer in [IncomingCallPrefs] regardless of
 * that permission, so Dart presents the call screen the instant the app is
 * next foregrounded — by this direct launch, or by the user tapping the
 * ordinary notification a moment later.
 */
class IncomingCallAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prayer = intent.getStringExtra(IncomingCallScheduling.EXTRA_PRAYER) ?: return
        val id = intent.getIntExtra(IncomingCallScheduling.EXTRA_ALARM_ID, -1)
        if (id != -1) IncomingCallPrefs.removeScheduledId(context, id)

        IncomingCallPrefs.setPendingPrayer(context, prayer)

        if (!Settings.canDrawOverlays(context)) return

        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        context.startActivity(launch)
    }
}

package com.salahinvite.allah_invites_you_to_salah

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * Exact-alarm scheduling for [IncomingCallAlarmReceiver] — fires at the
 * same moment as the ordinary prayer notification, but (when "Display over
 * other apps" is granted) force-launches the app directly instead of
 * relying on Android's full-screen intent, which the OS only auto-presents
 * while the device is locked.
 *
 * PendingIntent request codes are offset from the ordinary notification /
 * App Guard ids (which share the same deterministic `id`) so none collide.
 */
object IncomingCallScheduling {
    const val EXTRA_PRAYER = "prayer"
    const val EXTRA_ALARM_ID = "alarm_id"

    private const val ID_OFFSET = 200_000

    private fun pendingIntentFor(context: Context, id: Int): PendingIntent {
        val intent = Intent(context, IncomingCallAlarmReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            id + ID_OFFSET,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun schedule(context: Context, id: Int, prayer: String, triggerAtMillis: Long) {
        val intent = Intent(context, IncomingCallAlarmReceiver::class.java).apply {
            putExtra(EXTRA_PRAYER, prayer)
            putExtra(EXTRA_ALARM_ID, id)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            id + ID_OFFSET,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        try {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                triggerAtMillis,
                pendingIntent,
            )
        } catch (_: SecurityException) {
            // Exact-alarm permission revoked between scheduling calls; fall
            // back to an inexact alarm rather than silently dropping it.
            alarmManager.set(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
        }
        IncomingCallPrefs.addScheduledId(context, id)
    }

    fun cancel(context: Context, id: Int) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pendingIntentFor(context, id))
        IncomingCallPrefs.removeScheduledId(context, id)
    }

    fun cancelAll(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        IncomingCallPrefs.scheduledIds(context).forEach { id ->
            alarmManager.cancel(pendingIntentFor(context, id))
        }
        IncomingCallPrefs.clearScheduledIds(context)
    }
}

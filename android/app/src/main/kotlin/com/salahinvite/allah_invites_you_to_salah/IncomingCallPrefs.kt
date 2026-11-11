package com.salahinvite.allah_invites_you_to_salah

import android.content.Context

/**
 * Tiny SharedPreferences store backing [IncomingCallAlarmReceiver] /
 * [IncomingCallScheduling]: the one pending direct-launch prayer (consumed
 * by Dart the moment the app is foregrounded) and the set of alarm ids
 * currently scheduled (so `cancelAll` can actually cancel them all).
 */
object IncomingCallPrefs {
    private const val PREFS_NAME = "incoming_call_prefs"
    private const val KEY_PENDING_PRAYER = "pending_prayer"
    private const val KEY_SCHEDULED_IDS = "scheduled_ids"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun setPendingPrayer(context: Context, prayer: String) {
        prefs(context).edit().putString(KEY_PENDING_PRAYER, prayer).apply()
    }

    /** Reads and clears the pending prayer, if any. */
    fun consumePendingPrayer(context: Context): String? {
        val p = prefs(context)
        val value = p.getString(KEY_PENDING_PRAYER, null)
        if (value != null) p.edit().remove(KEY_PENDING_PRAYER).apply()
        return value
    }

    fun addScheduledId(context: Context, id: Int) {
        val p = prefs(context)
        val ids = (p.getStringSet(KEY_SCHEDULED_IDS, emptySet()) ?: emptySet()).toMutableSet()
        ids.add(id.toString())
        p.edit().putStringSet(KEY_SCHEDULED_IDS, ids).apply()
    }

    fun removeScheduledId(context: Context, id: Int) {
        val p = prefs(context)
        val ids = (p.getStringSet(KEY_SCHEDULED_IDS, emptySet()) ?: emptySet()).toMutableSet()
        ids.remove(id.toString())
        p.edit().putStringSet(KEY_SCHEDULED_IDS, ids).apply()
    }

    fun scheduledIds(context: Context): Set<Int> =
        (prefs(context).getStringSet(KEY_SCHEDULED_IDS, emptySet()) ?: emptySet())
            .mapNotNull { it.toIntOrNull() }
            .toSet()

    fun clearScheduledIds(context: Context) {
        prefs(context).edit().remove(KEY_SCHEDULED_IDS).apply()
    }
}

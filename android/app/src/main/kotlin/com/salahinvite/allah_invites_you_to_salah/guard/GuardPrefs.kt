package com.salahinvite.allah_invites_you_to_salah.guard

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Native-only persistence for App Guard, separate from the
 * `shared_preferences` plugin's store so the foreground service / receivers
 * (which run outside the Flutter engine, possibly with no Dart isolate
 * alive) never have to parse Flutter's key-prefixed prefs file.
 *
 * Written from [AppGuardPlugin] (Dart calls); read from
 * [AppGuardForegroundService], [GuardWindowAlarmReceiver] and
 * [GuardBootReceiver].
 */
object GuardPrefs {
    private const val FILE = "app_guard_prefs"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_PACKAGES = "guarded_packages"
    private const val KEY_PENDING = "pending_windows"

    /** One scheduled-but-not-yet-fired (or currently active) guard window. */
    data class PendingWindow(val id: Int, val triggerAtMillis: Long, val prayer: String)

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun guardedPackages(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_PACKAGES, emptySet()) ?: emptySet()

    fun setGuardedPackages(context: Context, packages: Collection<String>) {
        prefs(context).edit().putStringSet(KEY_PACKAGES, packages.toSet()).apply()
    }

    fun pendingWindows(context: Context): List<PendingWindow> {
        val raw = prefs(context).getString(KEY_PENDING, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                PendingWindow(obj.getInt("id"), obj.getLong("trigger"), obj.getString("prayer"))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun upsertPendingWindow(context: Context, window: PendingWindow) {
        val current = pendingWindows(context).filter { it.id != window.id }
        savePendingWindows(context, current + window)
    }

    fun removePendingWindow(context: Context, id: Int) {
        savePendingWindows(context, pendingWindows(context).filter { it.id != id })
    }

    fun clearAllPendingWindows(context: Context) {
        savePendingWindows(context, emptyList())
    }

    private fun savePendingWindows(context: Context, windows: List<PendingWindow>) {
        val array = JSONArray()
        windows.forEach { w ->
            val obj = JSONObject()
            obj.put("id", w.id)
            obj.put("trigger", w.triggerAtMillis)
            obj.put("prayer", w.prayer)
            array.put(obj)
        }
        prefs(context).edit().putString(KEY_PENDING, array.toString()).apply()
    }
}

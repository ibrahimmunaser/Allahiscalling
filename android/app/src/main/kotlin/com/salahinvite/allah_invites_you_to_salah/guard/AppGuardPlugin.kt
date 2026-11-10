package com.salahinvite.allah_invites_you_to_salah.guard

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import android.telecom.TelecomManager
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Dart-facing bridge for App Guard: permissions, the installed-apps picker,
 * and scheduling/cancelling the 15-minute guard window alongside each
 * primary prayer reminder (see `LocalNotificationService`, Android branch).
 */
class AppGuardPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    companion object {
        const val CHANNEL = "com.salahinvite.allah_invites_you_to_salah/app_guard"
    }

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {}
    override fun onDetachedFromActivityForConfigChanges() {}
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}
    override fun onDetachedFromActivity() {}

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        try {
            when (call.method) {
                "hasUsageAccess" -> result.success(hasUsageAccess())
                "requestUsageAccess" -> {
                    appContext.startActivity(
                        Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "hasOverlayPermission" -> result.success(hasOverlayPermission())
                "requestOverlayPermission" -> {
                    appContext.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:${appContext.packageName}"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "getInstalledApps" -> result.success(installedApps())
                "setGuardEnabled" -> {
                    GuardPrefs.setEnabled(appContext, call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "setGuardedPackages" -> {
                    @Suppress("UNCHECKED_CAST")
                    val packages = (call.argument<List<String>>("packages") ?: emptyList())
                    GuardPrefs.setGuardedPackages(appContext, packages)
                    result.success(null)
                }
                "scheduleGuardWindow" -> {
                    val id = call.argument<Int>("id") ?: return result.error(
                        "bad_args", "id is required", null
                    )
                    val prayer = call.argument<String>("prayer") ?: "Prayer"
                    val triggerAtMillis = (call.argument<Any>("triggerAtMillis") as? Number)?.toLong()
                        ?: return result.error("bad_args", "triggerAtMillis is required", null)
                    GuardScheduling.schedule(appContext, id, prayer, triggerAtMillis)
                    result.success(null)
                }
                "cancelGuardWindow" -> {
                    val id = call.argument<Int>("id") ?: return result.error(
                        "bad_args", "id is required", null
                    )
                    GuardScheduling.cancel(appContext, id)
                    result.success(null)
                }
                "cancelAllGuardWindows" -> {
                    GuardScheduling.cancelAll(appContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("app_guard_error", e.message, null)
        }
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = appContext.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                appContext.packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                appContext.packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun hasOverlayPermission(): Boolean = Settings.canDrawOverlays(appContext)

    /**
     * Launchable apps the user could choose to guard, excluding this app
     * itself, the default phone dialer, and the default SMS app (texting
     * and calling must never be blocked).
     */
    private fun installedApps(): List<Map<String, String>> {
        val pm = appContext.packageManager
        val mainIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val ownPackage = appContext.packageName
        val defaultDialer = try {
            (appContext.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager)
                ?.defaultDialerPackage
        } catch (_: Exception) {
            null
        }
        val defaultSms = try {
            android.provider.Telephony.Sms.getDefaultSmsPackage(appContext)
        } catch (_: Exception) {
            null
        }

        val resolveInfos = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(
                mainIntent,
                PackageManager.ResolveInfoFlags.of(0L),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(mainIntent, 0)
        }

        return resolveInfos
            .mapNotNull { info -> info.activityInfo?.packageName?.let { pkg -> pkg to info } }
            .distinctBy { it.first }
            .filter { (pkg, _) -> pkg != ownPackage && pkg != defaultDialer && pkg != defaultSms }
            .map { (pkg, info) ->
                mapOf(
                    "package" to pkg,
                    "label" to info.loadLabel(pm).toString(),
                )
            }
            .sortedBy { it["label"]?.lowercase() }
    }
}

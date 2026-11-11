package com.salahinvite.allah_invites_you_to_salah

import android.content.Context
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Dart-facing bridge for the direct-launch incoming-call alarm — see
 * [IncomingCallAlarmReceiver] / [IncomingCallScheduling].
 */
class IncomingCallPlugin : FlutterPlugin, MethodCallHandler {
    companion object {
        const val CHANNEL = "com.salahinvite.allah_invites_you_to_salah/incoming_call"
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

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        try {
            when (call.method) {
                "schedule" -> {
                    val id = call.argument<Int>("id")
                        ?: return result.error("bad_args", "id is required", null)
                    val prayer = call.argument<String>("prayer") ?: "Prayer"
                    val triggerAtMillis = (call.argument<Any>("triggerAtMillis") as? Number)?.toLong()
                        ?: return result.error("bad_args", "triggerAtMillis is required", null)
                    IncomingCallScheduling.schedule(appContext, id, prayer, triggerAtMillis)
                    result.success(null)
                }
                "cancel" -> {
                    val id = call.argument<Int>("id")
                        ?: return result.error("bad_args", "id is required", null)
                    IncomingCallScheduling.cancel(appContext, id)
                    result.success(null)
                }
                "cancelAll" -> {
                    IncomingCallScheduling.cancelAll(appContext)
                    result.success(null)
                }
                "consumePending" -> result.success(IncomingCallPrefs.consumePendingPrayer(appContext))
                "hasOverlayPermission" -> result.success(Settings.canDrawOverlays(appContext))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("incoming_call_error", e.message, null)
        }
    }
}

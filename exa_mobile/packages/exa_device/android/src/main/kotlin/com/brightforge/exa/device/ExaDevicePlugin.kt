package com.brightforge.exa.device

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `com.brightforge.exa/device` - Exa's device control.
 *
 * This is a Flutter *plugin* on purpose, not another MethodChannel in
 * MainActivity. The generated plugin registrant runs for every FlutterEngine
 * in the process - the app, the overlay engine, and the WorkManager / alarm
 * isolates that run scheduled jobs - so a channel registered here is live
 * wherever a tool might call it. A channel on the activity exists only in the
 * main engine, and "lock the phone every night at 23:00" runs in the
 * background isolate, where it would silently do nothing.
 *
 * Methods are namespaced by sub-API (`admin.*`, `screen.*`, ...). Every
 * method returns a map rather than throwing: `{"ok": true}` or
 * `{"ok": false, "error": "..."}` for actions, a status map for queries. A
 * tool reports those words faithfully; "not the device owner" is a different
 * outcome from "done", and this plugin never rounds one up to the other.
 */
class ExaDevicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.brightforge.exa/device"
    }

    private var channel: MethodChannel? = null
    private lateinit var context: Context
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /**
     * Screen work blocks: a gesture waits for its completion callback and a
     * screenshot for its frame, and that callback is delivered on the main
     * thread - so it must not be awaited on the main thread, or it
     * deadlocks. Every `screen.*` call runs on a worker thread and posts its
     * result back.
     */
    private fun runAsync(result: MethodChannel.Result, work: () -> Map<String, Any?>) {
        Thread {
            val out = try {
                Result.success(work())
            } catch (e: Exception) {
                Result.failure(e)
            }
            mainHandler.post {
                out.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        result.error("device_error", it.message ?: it::class.java.simpleName, null)
                    },
                )
            }
        }.start()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "admin.status" -> result.success(
                    AdminActions.status(
                        context,
                        listenerClass = call.argument<String>("listener"),
                        accessibilityClass = call.argument<String>("accessibility"),
                    ),
                )
                "admin.grantSelfRuntime" -> result.success(AdminActions.grantSelfRuntime(context))
                "admin.enableNotificationListener" -> result.success(
                    AdminActions.enableNotificationListener(
                        context,
                        call.argument<String>("component") ?: "",
                    ),
                )
                "admin.enableAccessibility" -> result.success(
                    AdminActions.enableAccessibility(
                        context,
                        call.argument<String>("component") ?: "",
                    ),
                )
                "admin.openSettings" -> result.success(
                    AdminActions.openSettings(context, call.argument<String>("screen") ?: ""),
                )
                "admin.requestBatteryExemption" -> result.success(
                    AdminActions.requestBatteryExemption(context),
                )
                "admin.clearDeviceOwner" -> result.success(AdminActions.clearDeviceOwner(context))
                "jobs.startService" -> result.success(JobServiceStarter.start(context))
                "screen.read" -> runAsync(result) { ScreenActions.read() }
                "screen.tap" -> runAsync(result) {
                    ScreenActions.tap(
                        call.argument<Int>("id"),
                        call.argument<Int>("x"),
                        call.argument<Int>("y"),
                    )
                }
                "screen.swipe" -> runAsync(result) {
                    ScreenActions.swipe(
                        context,
                        call.argument<String>("direction") ?: "up",
                        call.argument<Int>("x1"),
                        call.argument<Int>("y1"),
                        call.argument<Int>("x2"),
                        call.argument<Int>("y2"),
                    )
                }
                "screen.setText" -> runAsync(result) {
                    ScreenActions.setText(
                        call.argument<Int>("id") ?: -1,
                        call.argument<String>("text") ?: "",
                    )
                }
                "screen.global" -> runAsync(result) {
                    ScreenActions.global(call.argument<String>("action") ?: "")
                }
                "screen.openApp" -> runAsync(result) {
                    ScreenActions.openApp(context, call.argument<String>("package") ?: "")
                }
                "screen.screenshot" -> runAsync(result) { ScreenActions.screenshot() }
                // push.* runs a dumpsys and, for the restart, sleeps while
                // Play services is hidden - neither belongs on the main thread.
                "push.status" -> runAsync(result) { PushHealth.status(context) }
                "push.restartPlayServices" -> runAsync(result) {
                    PushHealth.restartPlayServices(context)
                }
                "push.reboot" -> runAsync(result) { PushHealth.reboot(context) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("device_error", e.message ?: e::class.java.simpleName, null)
        }
    }
}

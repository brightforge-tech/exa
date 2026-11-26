package com.brightforge.exa.voice

import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * `com.brightforge.exa/voice`: the assistant role, the "Hey Exa" listener,
 * follow-up notifications, and the voice session's own launch details.
 *
 * A plugin rather than a channel on an activity for the same reason as
 * exa_phone: follow-ups are mostly raised by scheduled jobs, which run in
 * background engines that never see an activity's channels.
 */
class ExaVoicePlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.NewIntentListener,
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.brightforge.exa/voice"
    }

    private var channel: MethodChannel? = null
    private lateinit var context: Context
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    /** The launch the voice session has not read yet. */
    private var pendingLaunch: Map<String, Any?>? = null

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

    // ------------------------------------------------------------ activity

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        captureLaunch(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        if (captureLaunch(intent)) {
            // Pushed as well as stored: a session already on screen has to
            // switch to the new follow-up without waiting to be asked.
            channel?.invokeMethod("launch", pendingLaunch)
        }
        return false
    }

    private fun captureLaunch(intent: Intent?): Boolean {
        if (intent == null) return false
        val isAssist = intent.action == Intent.ACTION_ASSIST ||
            intent.action == Intent.ACTION_VOICE_COMMAND
        val mode = intent.getStringExtra(VoiceLauncher.EXTRA_MODE)
            ?: if (isAssist) VoiceLauncher.MODE_LISTEN else return false
        pendingLaunch = mapOf(
            "mode" to mode,
            "prompt" to intent.getStringExtra(VoiceLauncher.EXTRA_PROMPT),
            "speak" to intent.getStringExtra(VoiceLauncher.EXTRA_SPEAK),
            "follow_up_id" to intent.getStringExtra(VoiceLauncher.EXTRA_FOLLOW_UP_ID),
        )
        return true
    }

    // ------------------------------------------------------------- methods

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(status())
                "consumeLaunch" -> {
                    result.success(pendingLaunch)
                    pendingLaunch = null
                }
                "isLocked" -> result.success(VoiceLauncher.isLocked(context))
                "finishSession" -> {
                    activity?.finishAndRemoveTask()
                    result.success(null)
                }
                "openSession" -> result.success(
                    VoiceLauncher.open(
                        context,
                        call.argument<String>("mode") ?: VoiceLauncher.MODE_LISTEN,
                        call.argument<String>("prompt"),
                        call.argument<String>("speak"),
                        call.argument<String>("follow_up_id"),
                    ),
                )
                "postFollowUp" -> {
                    val delivered = VoiceLauncher.postFollowUp(
                        context,
                        id = call.argument<Int>("notification_id") ?: 7500,
                        title = call.argument<String>("title") ?: "Exa",
                        body = call.argument<String>("body") ?: "",
                        prompt = call.argument<String>("prompt") ?: "",
                        speak = call.argument<String>("speak"),
                        followUpId = call.argument<String>("follow_up_id"),
                        ring = call.argument<Boolean>("ring") ?: false,
                    )
                    result.success(delivered)
                }
                "cancelFollowUp" -> {
                    VoiceLauncher.cancel(context, call.argument<Int>("notification_id") ?: 0)
                    result.success(null)
                }
                "configureWakeWord" -> {
                    val edit = WakeWordService.prefs(context).edit()
                    call.argument<String>("phrase")?.let {
                        edit.putString(WakeWordService.KEY_PHRASE, it.trim())
                    }
                    call.argument<String>("keywords")?.let {
                        edit.putString(WakeWordService.KEY_KEYWORDS, it)
                    }
                    call.argument<Double>("threshold")?.let {
                        edit.putFloat(WakeWordService.KEY_THRESHOLD, it.toFloat())
                    }
                    // commit, not apply: the service reads these the moment
                    // the reload below reaches it.
                    edit.commit()
                    WakeWordService.send(context, WakeWordService.ACTION_RELOAD)
                    result.success(status())
                }
                "setWakeWordEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    WakeWordService.prefs(context).edit()
                        .putBoolean(WakeWordService.KEY_ENABLED, enabled)
                        .apply()
                    WakeWordService.send(
                        context,
                        if (enabled) WakeWordService.ACTION_START else WakeWordService.ACTION_STOP,
                    )
                    result.success(status())
                }
                "ensureWakeWord" -> {
                    // Called when the app comes to the front: the one moment
                    // Android lets a microphone service start, so a listener
                    // lost to a reboot comes back here.
                    if (WakeWordService.prefs(context)
                            .getBoolean(WakeWordService.KEY_ENABLED, false) &&
                        !WakeWordService.isRunning
                    ) {
                        WakeWordService.send(context, WakeWordService.ACTION_START)
                    }
                    result.success(null)
                }
                "pauseWakeWord" -> {
                    WakeWordService.send(context, WakeWordService.ACTION_PAUSE)
                    result.success(null)
                }
                "resumeWakeWord" -> {
                    WakeWordService.send(context, WakeWordService.ACTION_RESUME)
                    result.success(null)
                }
                "openAssistantSettings" -> {
                    openSettings(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                    result.success(null)
                }
                "openFullScreenSettings" -> {
                    if (Build.VERSION.SDK_INT >= 34) {
                        openSettings(
                            Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                            Uri.parse("package:${context.packageName}"),
                        )
                    }
                    result.success(null)
                }
                "openOverlaySettings" -> {
                    openSettings(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${context.packageName}"),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("voice_error", e.message, null)
        }
    }

    private fun status(): Map<String, Any?> {
        val prefs = WakeWordService.prefs(context)
        return mapOf(
            "is_assistant" to isAssistant(),
            "wake_enabled" to prefs.getBoolean(WakeWordService.KEY_ENABLED, false),
            "wake_configured" to WakeWordService.isConfigured(context),
            "wake_running" to WakeWordService.isRunning,
            "wake_listening" to WakeWordService.isListening,
            "wake_error" to prefs.getString(WakeWordService.KEY_LAST_ERROR, null),
            "wake_phrase" to (prefs.getString(WakeWordService.KEY_PHRASE, null)
                ?: WakeWordService.DEFAULT_PHRASE),
            "wake_keywords" to prefs.getString(WakeWordService.KEY_KEYWORDS, null),
            "wake_detections" to prefs.getInt(WakeWordService.KEY_DETECTIONS, 0),
            "wake_last_detection" to prefs.getLong(WakeWordService.KEY_LAST_DETECTION, 0L),
            "wake_threshold" to prefs.getFloat(
                WakeWordService.KEY_THRESHOLD,
                WakeWordService.DEFAULT_THRESHOLD,
            ).toDouble(),
            "can_full_screen" to VoiceLauncher.canUseFullScreen(context),
            "can_open_from_background" to VoiceLauncher.canStartFromBackground(context),
            "locked" to VoiceLauncher.isLocked(context),
        )
    }

    private fun isAssistant(): Boolean {
        val roles = context.getSystemService(RoleManager::class.java) ?: return false
        return try {
            roles.isRoleAvailable(RoleManager.ROLE_ASSISTANT) &&
                roles.isRoleHeld(RoleManager.ROLE_ASSISTANT)
        } catch (e: Exception) {
            false
        }
    }

    private fun openSettings(action: String, data: Uri? = null) {
        val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (data != null) intent.data = data
        try {
            (activity ?: context).startActivity(intent)
        } catch (e: Exception) {
            context.startActivity(
                Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}

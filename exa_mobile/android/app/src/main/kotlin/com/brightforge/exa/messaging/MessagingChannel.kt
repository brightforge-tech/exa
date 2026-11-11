package com.brightforge.exa.messaging

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * `com.brightforge.exa/messaging` — the control plane for chat capture.
 *
 * Note what is *not* here: draining captured messages. That happens by
 * reading [MessageSpool]'s file straight from Dart, because the drain runs in
 * the WorkManager isolate, which never sees the channels this activity
 * registers. A method here would work in the foreground and silently do
 * nothing in the background.
 *
 * What is here is everything that genuinely needs an Activity or the live
 * notification service: the permission flow, the allowlist, the shared-item
 * handoff, and sending a reply — which can only be done from the process
 * holding the notification's own `PendingIntent`. That the reply path
 * therefore cannot run in a background isolate is a happy accident: replying
 * is an outbound action, and outbound actions are not for unattended runs.
 */
class MessagingChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "com.brightforge.exa/messaging"
    }

    /** Set from the launch intent; cleared once Dart has taken it. */
    private var pendingShared: Map<String, Any?>? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasNotificationAccess" ->
                    result.success(NotificationAccess.isGranted(activity))

                "openNotificationAccessSettings" -> {
                    activity.startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS),
                    )
                    result.success(null)
                }

                // A fresh grant does not always bind the service immediately;
                // without this the user grants access, sees "not connected",
                // and reasonably concludes it did not work.
                "rebindListener" -> {
                    NotificationAccess.rebind(activity)
                    result.success(null)
                }

                "isListenerConnected" ->
                    result.success(ExaNotificationListener.isConnected)

                "isCaptureEnabled" ->
                    result.success(ChatPackages.isCaptureEnabled(activity))

                "setCaptureEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    ChatPackages.setCaptureEnabled(activity, enabled)
                    if (enabled) NotificationAccess.rebind(activity)
                    result.success(true)
                }

                "supportedApps" ->
                    result.success(ChatPackages.installedSupported(activity))

                "allowedPackages" ->
                    result.success(ChatPackages.allowedPackages(activity).toList())

                "setAllowedPackages" -> {
                    val packages =
                        call.argument<List<String>>("packages") ?: emptyList()
                    ChatPackages.setAllowedPackages(activity, packages)
                    result.success(
                        ChatPackages.allowedPackages(activity).toList(),
                    )
                }

                // Authoritative path, so Dart never has to assume
                // path_provider's mapping of filesDir stays what it is today.
                "spoolPath" ->
                    result.success(
                        File(activity.filesDir, MessageSpool.FILE_NAME).absolutePath,
                    )

                "spoolPendingCount" ->
                    result.success(MessageSpool.pendingCount(activity))

                "droppedCount" -> {
                    val prefs = activity.getSharedPreferences(
                        ChatPackages.PREFS, Context.MODE_PRIVATE,
                    )
                    result.success(prefs.getInt(MessageSpool.KEY_DROPPED, 0))
                }

                "clearDroppedCount" -> {
                    activity.getSharedPreferences(
                        ChatPackages.PREFS, Context.MODE_PRIVATE,
                    ).edit().putInt(MessageSpool.KEY_DROPPED, 0).apply()
                    result.success(null)
                }

                "clearSpool" -> {
                    MessageSpool.clear(activity)
                    result.success(null)
                }

                // Read-only media-probe matrix (see ChatPackages): the C3
                // spike's whole point is a result a developer can review
                // without an adb session, and this is the only place the
                // spike surfaces it. No arguments; nothing is recorded.
                "mediaProbeReport" ->
                    result.success(ChatPackages.mediaProbeReport(activity))

                "canReply" -> {
                    val channel = call.argument<String>("channel")
                    val conversationId = call.argument<String>("conversation_id")
                    if (channel == null || conversationId == null) {
                        result.error("bad_args", "channel and conversation_id required", null)
                    } else {
                        result.success(ReplyRegistry.canReply(channel, conversationId))
                    }
                }

                "replyableChats" -> result.success(ReplyRegistry.replyableKeys())

                "sendReply" -> {
                    val channel = call.argument<String>("channel")
                    val conversationId = call.argument<String>("conversation_id")
                    val text = call.argument<String>("text")
                    if (channel == null || conversationId == null || text.isNullOrBlank()) {
                        result.error(
                            "bad_args",
                            "channel, conversation_id and a non-empty text are required",
                            null,
                        )
                    } else {
                        // null = delivered; a string is the reason it was not.
                        result.success(
                            ReplyRegistry.send(activity, channel, conversationId, text),
                        )
                    }
                }

                "consumeSharedItem" -> {
                    result.success(pendingShared)
                    pendingShared = null
                }

                else -> result.notImplemented()
            }
        }
    }

    /** Called from the activity's intent hooks. */
    fun offerIntent(intent: Intent?) {
        SharedIntake.parse(activity, intent)?.let { pendingShared = it }
    }
}

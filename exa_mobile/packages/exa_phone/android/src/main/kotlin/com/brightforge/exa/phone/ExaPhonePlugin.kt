package com.brightforge.exa.phone

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `com.brightforge.exa/phone` - Exa's phone access: SMS, calls, the WhatsApp
 * hand-off, contact lookup, and the device state that decides whether a
 * scheduled call should dial now or hand the user a tap-to-call notification.
 *
 * This is a Flutter *plugin* on purpose, not another MethodChannel in
 * MainActivity. The generated plugin registrant runs for every FlutterEngine
 * in the process - the app, the overlay engine, and the WorkManager / alarm
 * isolates that run scheduled jobs - so a channel registered here is live
 * wherever a tool might call it. A channel on the activity exists only in the
 * main engine, and "send a text every Friday at 17:00" runs in the background
 * isolate, where it would silently do nothing.
 *
 * Every method returns a result map rather than throwing: `{"status": ...}`
 * where the status is one of `sent`, `placed`, `dialer_opened`,
 * `composer_opened`, `notified`, or `failed` (with `error`). A tool reports
 * those words to the user faithfully - "WhatsApp was opened with the message,
 * tap Send" is a different outcome from "sent", and saying "sent" for it is
 * the one thing this plugin must never do.
 */
class ExaPhonePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.brightforge.exa/phone"

        /**
         * Lent by the app at startup (see `ExaApplication`). A WhatsApp
         * message can be answered without opening WhatsApp only through the
         * reply action WhatsApp attached to *its own* notification, and those
         * handles live in the app's `ReplyRegistry`. This module cannot depend
         * on the app, so the app installs the delegate; until it does, direct
         * replies simply report as unavailable.
         */
        @Volatile
        var replyDelegate: ReplyDelegate? = null
    }

    /** Bridge to the app's notification reply handles. */
    interface ReplyDelegate {
        fun canReply(channel: String, conversationId: String): Boolean

        /** Null on success, or the reason the reply was not delivered. */
        fun send(
            context: Context,
            channel: String,
            conversationId: String,
            text: String,
        ): String?
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "permissions" -> result.success(PhoneActions.permissions(context))
                "deviceState" -> result.success(PhoneActions.deviceState(context))
                "normalizeNumber" -> result.success(
                    PhoneActions.normalize(context, call.argument<String>("number") ?: ""),
                )
                "findContacts" -> {
                    val query = call.argument<String>("query") ?: ""
                    val limit = call.argument<Int>("limit") ?: 10
                    // A content-provider query on the platform thread would
                    // stall the UI of whichever engine asked; contacts can be
                    // large.
                    Thread {
                        val outcome = try {
                            Result.success(PhoneActions.findContacts(context, query, limit))
                        } catch (e: Exception) {
                            Result.failure(e)
                        }
                        mainHandler.post {
                            outcome.fold(
                                onSuccess = { result.success(it) },
                                onFailure = {
                                    result.error(
                                        "contacts_failed",
                                        it.message ?: it::class.java.simpleName,
                                        null,
                                    )
                                },
                            )
                        }
                    }.start()
                }
                "sendSms" -> result.success(
                    PhoneActions.sendSms(
                        context,
                        call.argument<String>("number") ?: "",
                        call.argument<String>("text") ?: "",
                    ),
                )
                "placeCall" -> result.success(
                    PhoneActions.placeCall(context, call.argument<String>("number") ?: ""),
                )
                "openWhatsApp" -> result.success(
                    PhoneActions.openWhatsApp(
                        context,
                        call.argument<String>("number"),
                        call.argument<String>("text") ?: "",
                        call.argument<Boolean>("business") ?: false,
                    ),
                )
                "isInstalled" -> result.success(
                    PhoneActions.isInstalled(context, call.argument<String>("package") ?: ""),
                )
                "notifyPhoneAction" -> result.success(
                    PhoneActions.notifyAction(
                        context,
                        kind = call.argument<String>("kind") ?: "",
                        number = call.argument<String>("number"),
                        text = call.argument<String>("text") ?: "",
                        title = call.argument<String>("title") ?: "Exa",
                        body = call.argument<String>("body") ?: "",
                    ),
                )
                "canDirectReply" -> {
                    val chatChannel = call.argument<String>("channel")
                    val conversationId = call.argument<String>("conversation_id")
                    val delegate = replyDelegate
                    result.success(
                        chatChannel != null && conversationId != null && delegate != null &&
                            delegate.canReply(chatChannel, conversationId),
                    )
                }
                "directReply" -> {
                    val chatChannel = call.argument<String>("channel")
                    val conversationId = call.argument<String>("conversation_id")
                    val text = call.argument<String>("text")
                    val delegate = replyDelegate
                    when {
                        chatChannel == null || conversationId == null || text.isNullOrBlank() ->
                            result.error("bad_args", "channel, conversation_id and text are required", null)
                        delegate == null -> result.success(
                            "Replying through the chat's own notification is not available here.",
                        )
                        // null = delivered; a string is the reason it was not.
                        else -> result.success(delegate.send(context, chatChannel, conversationId, text))
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("phone_error", e.message ?: e::class.java.simpleName, null)
        }
    }
}

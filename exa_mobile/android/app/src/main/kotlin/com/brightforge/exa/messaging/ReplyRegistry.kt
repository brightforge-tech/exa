package com.brightforge.exa.messaging

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log

/**
 * The live reply actions Exa is currently holding, one per chat.
 *
 * A direct reply is not a message Exa composes and sends — it is Android
 * handing back the `PendingIntent` that WhatsApp attached to *its own*
 * notification. That intent is only valid while the notification exists, so
 * this cannot be persisted: a `PendingIntent` is not serializable, and one
 * recovered from a dismissed notification would fail in the app's own code
 * rather than in ours.
 *
 * So the contract is deliberately narrow and honest: replies work while the
 * message is still unread in the shade, and fail with a clear reason once it
 * is not. Reporting "sent" for a reply that went nowhere is the one outcome
 * worth engineering against.
 *
 * In-memory only, keyed by `channel|conversationId`. If the process is killed
 * the map is empty and every reply is refused until the next message arrives
 * — which is the safe direction: the alternative is a stale intent.
 */
object ReplyRegistry {
    private const val TAG = "ExaReplyRegistry"

    private data class Handle(
        val packageName: String,
        val intent: PendingIntent,
        val remoteInput: RemoteInput,
        val extraInputs: Array<RemoteInput>,
    )

    private val handles = mutableMapOf<String, Handle>()

    fun keyFor(channel: String, conversationId: String) =
        "$channel|$conversationId"

    fun remember(
        channel: String,
        conversationId: String,
        packageName: String,
        intent: PendingIntent,
        remoteInput: RemoteInput,
        extraInputs: Array<RemoteInput>,
    ) {
        synchronized(handles) {
            handles[keyFor(channel, conversationId)] =
                Handle(packageName, intent, remoteInput, extraInputs)
        }
    }

    fun forget(channel: String, conversationId: String) {
        synchronized(handles) { handles.remove(keyFor(channel, conversationId)) }
    }

    fun canReply(channel: String, conversationId: String): Boolean =
        synchronized(handles) { handles.containsKey(keyFor(channel, conversationId)) }

    /** Chats a reply could reach right now. */
    fun replyableKeys(): List<String> =
        synchronized(handles) { handles.keys.toList() }

    /**
     * Delivers [text] to the chat's own app. Returns null on success, or the
     * reason it could not be sent.
     */
    fun send(
        context: Context,
        channel: String,
        conversationId: String,
        text: String,
    ): String? {
        val handle = synchronized(handles) { handles[keyFor(channel, conversationId)] }
            ?: return "No live notification for this chat, so there is nothing " +
                "to reply through. Android only allows a reply while the " +
                "message is still unread in the notification shade - it was " +
                "either already read elsewhere or dismissed. Reply in the app " +
                "instead."
        return try {
            val results = Bundle().apply {
                putCharSequence(handle.remoteInput.resultKey, text)
            }
            val intent = Intent()
            // Every RemoteInput the action declares has to be present, not
            // just the one being filled: RemoteInput.addResultsToIntent
            // rebuilds the whole result set, and an app that declares two
            // inputs reads back nothing when only one is supplied.
            RemoteInput.addResultsToIntent(handle.extraInputs, intent, results)
            // Sending marks the conversation read in most clients, which is
            // the behaviour a user expects from having answered it.
            RemoteInput.setResultsSource(
                intent,
                RemoteInput.SOURCE_FREE_FORM_INPUT,
            )
            handle.intent.send(context, 0, intent)
            null
        } catch (e: PendingIntent.CanceledException) {
            forget(channel, conversationId)
            "The chat app withdrew its reply action before the message could " +
                "be delivered. Nothing was sent."
        } catch (e: Exception) {
            Log.w(TAG, "Reply failed", e)
            "Reply failed: ${e.message ?: e::class.java.simpleName}"
        }
    }
}

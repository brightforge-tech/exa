package com.brightforge.exa.messaging

import android.app.Notification
import android.app.Person
import android.app.RemoteInput
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/**
 * Reads messages out of chat-app notifications and spools them for Dart.
 *
 * This is the only way to see personal WhatsApp messages on Android:
 * WhatsApp's Business Cloud API only receives mail addressed to a registered
 * business number and cannot be attached to a number already on the consumer
 * app, and the local message store is encrypted with a key that needs root.
 *
 * What that costs, stated plainly because the UI has to say it too:
 *  - **No history.** Only messages that arrive after the grant, and only
 *    those the app actually posts a notification for. A chat open on screen
 *    posts nothing.
 *  - **Sometimes truncated.** A notification carries what the shade shows.
 *  - **Media is copied, then described.** A photo or voice note on an
 *    allowlisted app's `MessagingStyle` message is read from the posting
 *    app's content URI and copied to a sidecar file next to the spool (see
 *    [NotificationMedia]); the message itself stays text, and the media
 *    rides its own spool line attached to it. Where the posting app will
 *    not let the URI be opened, the message is stored with an honest
 *    could-not-read note instead of silently losing the fact that a photo
 *    was there. No media bytes ever enter the spool file.
 *  - **Replies are borrowed.** See [ReplyRegistry].
 *
 * The counterweight is that the same `MessagingStyle` API serves Signal,
 * Telegram and SMS identically, so [ChatPackages] is what decides scope
 * rather than any code here.
 *
 * ### Reading as little as possible
 *
 * Notification access is device-wide: this service is offered every OTP,
 * banking alert and private notification on the phone. So the allowlist check
 * is the *first* statement in [onNotificationPosted], before anything is
 * read out of the notification at all, and nothing is kept, logged or spooled
 * for a package the user has not chosen.
 */
class ExaNotificationListener : NotificationListenerService() {

    companion object {
        private const val TAG = "ExaNotifListener"

        /** Temporary capture-diagnostic tag; grep `adb logcat -s ExaNotifDbg`. */
        private const val DBG = "ExaNotifDbg"

        /** Bundle keys inside `Notification.EXTRA_MESSAGES` entries. */
        private const val MSG_TEXT = "text"
        private const val MSG_TIME = "time"
        private const val MSG_SENDER = "sender"
        private const val MSG_SENDER_PERSON = "sender_person"

        /**
         * Summary notifications ("5 messages from 2 chats") carry no content
         * worth keeping and would otherwise be stored as a message whose
         * body is a count.
         */
        private val SUMMARY_PATTERN =
            Regex("""^\d+\s+(new\s+)?messages?( from .+)?$""", RegexOption.IGNORE_CASE)

        @Volatile
        var isConnected: Boolean = false
            private set
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        isConnected = true
        replayActiveNotifications()
    }

    /**
     * Captures what is already in the shade when the service binds.
     *
     * The system binds this service on its own schedule - about 90 s after
     * boot on the S8+, and again after every app update - and nothing posted
     * before then is ever offered to [onNotificationPosted]. After a reboot
     * that is exactly the backlog a push reconnect has just delivered (42
     * Teams messages in 15 s, all missed). Re-reading the shade costs
     * nothing: the Dart side dedupes by content hash, and "already seen" is
     * the normal steady state of a MessagingStyle re-post anyway. Same rule
     * as [onNotificationPosted]: nothing is read for a package the user did
     * not pick.
     */
    private fun replayActiveNotifications() {
        val active = try {
            activeNotifications
        } catch (e: Exception) {
            // Not actually bound yet, or the binder is gone: nothing to
            // replay, and the next post arrives the normal way.
            null
        } ?: return
        for (sbn in active) {
            if (!ChatPackages.shouldCapture(this, sbn.packageName)) continue
            onNotificationPosted(sbn)
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        isConnected = false
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        // First statement on purpose: for every app the user did not pick,
        // this service reads nothing out of the notification at all - not
        // for capture, not for the media probe below, not even for logging.
        // (The ExaNotifDbg diagnostic used to sit above this gate and read
        // titles and previews of known-but-unallowed chat apps; that was
        // device-wide snooping in a log line and it is now behind the gate.)
        if (!ChatPackages.shouldCapture(this, sbn.packageName)) return

        // Temporary diagnostic (ExaNotifDbg): log what the notification
        // looks like for an app the user allowed capture for, so a
        // "messages aren't showing up" report can be traced from adb
        // logcat without guessing. It sits behind the gate above: logging
        // titles and previews of known-but-unallowed chat apps would itself
        // be device-wide notification snooping.
        val notification = sbn.notification
        val ex = notification.extras
        Log.i(
            DBG,
            "posted pkg=${sbn.packageName} " +
                "flags=${notification.flags} " +
                "title=${ex.getCharSequence(Notification.EXTRA_TITLE)?.take(40)} " +
                "text=${ex.getCharSequence(Notification.EXTRA_TEXT)?.take(40)} " +
                "hasMessages=${ex.getParcelableArray(Notification.EXTRA_MESSAGES) != null} " +
                "bigText=${ex.getCharSequence(Notification.EXTRA_BIG_TEXT)?.take(40)}",
        )
        val channel = ChatPackages.channelFor(sbn.packageName) ?: return

        try {
            capture(channel, sbn)
        } catch (e: Exception) {
            // A throw here is a listener the system may stop calling, which
            // would silently end capture until the next reboot.
            Log.w(TAG, "Could not read a notification", e)
        }

        // The C3 media probe. Reached only past the allowlist gate above,
        // and deliberately not on this thread: opening another app's
        // content provider can block, and a blocked or thrown callback is
        // the system quietly stopping this listener. One thread so a probe
        // storm is serialised, a bounded queue with DiscardOldest so a
        // backlog can never grow without bound (probing a fifteen-minute-old
        // notification adds nothing the live one will not show), and the
        // whole body is caught because an uncaught throw on this worker
        // would crash the app while Exa was merely watching the shade.
        // Spool output is untouched: the probe records, it never captures.
        val packageName = sbn.packageName
        mediaProbeExecutor.execute {
            try {
                val extras = notification.extras
                val bigPicture = bigPictureUri(extras)
                val candidates = NotificationMedia.mediaCandidates(
                    rawMessageBundles(extras),
                    bigPicture,
                )
                for (candidate in candidates) {
                    val result = NotificationMedia.probe(contentResolver, packageName, candidate)
                    val origin = candidate.origin.label()
                    val scheme = result.scheme ?: "none"
                    val mime = result.mimeType ?: "none"
                    val bytes = result.bytesRead
                    val failure = result.failure.label()
                    // Log and persist the same facts only - package, URI
                    // scheme, mime type, byte count, failure class: a content
                    // URI can carry a signed or expiring token, so the URI
                    // itself, notification text and media bytes must never
                    // reach a log line or the report. The origin says which
                    // notification slot the probe came from and is stored in
                    // the report so an avatar can never be confused with a
                    // message attachment.
                    Log.i(
                        DBG,
                        "mediaProbe pkg=$packageName scheme=$scheme mime=$mime " +
                            "bytes=$bytes failure=$failure",
                    )
                    ChatPackages.recordMediaProbe(
                        this,
                        packageName,
                        origin,
                        result.scheme,
                        result.mimeType,
                        bytes,
                        failure,
                    )
                }
            } catch (e: Exception) {
                Log.w(DBG, "mediaProbe pkg=$packageName failed: " + e.javaClass.simpleName)
            }
        }
    }

    /**
     * The single worker all media work runs on: the probe and the capture
     * copy alike. Created once per service instance (there is effectively
     * one listener process-wide), and never used for anything that talks to
     * Dart over a channel - its outputs are the SharedPreferences report
     * and spool-line appends, both of which outlive the service like the
     * spool itself does. One thread serialises provider reads and file
     * copies; a bounded queue with DiscardOldest means a media storm sheds
     * work rather than growing without bound, and shed capture work simply
     * means media that was never claimed - the safe direction to fail.
     */
    private val mediaProbeExecutor = ThreadPoolExecutor(
        1,
        1,
        1L,
        TimeUnit.SECONDS,
        ArrayBlockingQueue(16),
        ThreadPoolExecutor.DiscardOldestPolicy(),
    ).apply { allowCoreThreadTimeOut(true) }

    /**
     * The raw `EXTRA_MESSAGES` bundles, read with framework APIs only -
     * see [messageEntries] for why androidx is deliberately absent. The
     * probe maps them itself so the two parsers can never disagree about
     * what a message is; they just read the same array from the same extras.
     */
    private fun rawMessageBundles(extras: Bundle): Array<Parcelable>? {
        return if (Build.VERSION.SDK_INT >= 33) {
            extras.getParcelableArray(Notification.EXTRA_MESSAGES, Parcelable::class.java)
        } else {
            @Suppress("DEPRECATION")
            extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        }
    }

    /**
     * `Notification.EXTRA_PICTURE`, or null. Null covers the important
     * case: apps may put a Bitmap here rather than a Uri, and a bitmap is
     * exactly the (often avatar) picture the spike must *not* misread as a
     * message attachment - [NotificationMedia] records a real Uri under the
     * `notification_picture` origin, which no capture path may persist.
     */
    private fun bigPictureUri(extras: Bundle): Uri? {
        return if (Build.VERSION.SDK_INT >= 33) {
            extras.getParcelable(Notification.EXTRA_PICTURE, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            extras.getParcelable(Notification.EXTRA_PICTURE) as? Uri
        }
    }

    private fun capture(channel: String, sbn: StatusBarNotification) {
        val notification = sbn.notification
        val flags = notification.flags
        // A group summary duplicates its children; an ongoing notification is
        // a call or a backup, not a message.
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (flags and Notification.FLAG_ONGOING_EVENT != 0) return

        val extras = notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return

        val isGroup = extras.getBoolean(
            Notification.EXTRA_IS_GROUP_CONVERSATION,
            false,
        )

        // The chat's display name is the conversation key, normalized.
        //
        // Not the notification key or tag, which look more precise and are
        // not: they change between app updates and carry a jid Exa can show
        // nobody. The title is also the only key a chat *export* can supply,
        // and messages captured live have to land in the same conversation as
        // messages imported from that chat's history or "scan my chat with
        // Alice" reads half of it. Two chats sharing a name merging is the
        // accepted cost, and it is visible to the user rather than silent.
        val conversationId = title.lowercase()

        val replyable = rememberReply(channel, conversationId, sbn)
        val entries = messageEntries(extras)

        if (entries.isEmpty()) {
            // No MessagingStyle: fall back to the flat text, which is what
            // SMS and older clients post.
            val text = extras.getCharSequence(Notification.EXTRA_TEXT)
                ?.toString()?.trim()
            if (text.isNullOrEmpty() || SUMMARY_PATTERN.matches(text)) return
            spool(
                channel = channel,
                packageName = sbn.packageName,
                conversationId = conversationId,
                title = title,
                isGroup = isGroup,
                // A one-to-one notification's title *is* the sender; in a
                // group it is the group, and the real sender is unknown here.
                sender = if (isGroup) null else title,
                body = text,
                sentAt = sbn.postTime,
                canReply = replyable,
            )
            return
        }

        // MessagingStyle re-posts every recent message in the chat on each
        // new arrival, so this is mostly messages already seen. They are
        // spooled anyway and deduped by content hash on the Dart side, which
        // is the only place that can tell - the notification carries no id.
        for (entry in entries) {
            val body = entry.text?.trim()
            val sender = entry.sender ?: if (isGroup) null else title
            val sentAt = if (entry.time > 0) entry.time else sbn.postTime

            // The media hand-off happens BEFORE the empty-body `continue`:
            // a photo-only message is exactly an empty body with a URI, and
            // skipping it here is how media-only messages stayed invisible.
            // The text append above stays synchronous and the media copy
            // never happens on this thread - see [submitMediaCapture].
            if (entry.media != null) {
                submitMediaCapture(
                    channel = channel,
                    packageName = sbn.packageName,
                    conversationId = conversationId,
                    title = title,
                    isGroup = isGroup,
                    sender = sender,
                    sentAt = sentAt,
                    canReply = replyable,
                    candidate = entry.media,
                )
            }
            if (body.isNullOrEmpty()) continue
            spool(
                channel = channel,
                packageName = sbn.packageName,
                conversationId = conversationId,
                title = title,
                isGroup = isGroup,
                sender = sender,
                body = body,
                sentAt = sentAt,
                canReply = replyable,
            )
        }
    }

    /**
     * Copies one message's advertised media on the shared media worker and
     * appends one separate JSONL line describing it.
     *
     * Why a second line and not a field on the text line: the copy runs
     * after the text has already been spooled (it must not delay the
     * callback thread's file write, let alone block on a provider), and the
     * spool is append-only - there is nothing to rewrite. Dart resolves the
     * media line to its message by identity, the same fields repeated here;
     * if the queue dropped this job, or the process died before it ran, no
     * line exists and no media is claimed - the message keeps its text,
     * exactly as if the media had never been advertised.
     *
     * The line never carries bytes or URIs: kind, mime, the bare sidecar
     * basename, its size, its sha256, and its origin - nothing else. At
     * most [NotificationMedia.MAX_MEDIA_ITEMS_PER_MESSAGE] items per
     * message. A candidate that could not be copied counts into
     * `media_unreadable` so Dart can store the honest note.
     */
    private fun submitMediaCapture(
        channel: String,
        packageName: String,
        conversationId: String,
        title: String,
        isGroup: Boolean,
        sender: String?,
        sentAt: Long,
        canReply: Boolean,
        candidate: NotificationMedia.Candidate,
    ) {
        mediaProbeExecutor.execute {
            try {
                val captured = NotificationMedia.capture(this, packageName, candidate)
                val line = JSONObject().apply {
                    put("channel", channel)
                    put("package", packageName)
                    put("conversation_id", conversationId)
                    put("conversation_title", title)
                    put("is_group", isGroup)
                    if (sender != null) put("sender", sender)
                    put("sent_at", sentAt)
                    put("can_reply", canReply)
                    if (captured != null) {
                        put(
                            "media",
                            org.json.JSONArray().put(
                                JSONObject().apply {
                                    put("kind", captured.kind)
                                    if (captured.mimeType != null) {
                                        put("mime_type", captured.mimeType)
                                    }
                                    put("file", captured.file)
                                    put("size_bytes", captured.sizeBytes)
                                    put("content_hash", captured.contentHash)
                                    put("origin", captured.origin.label())
                                },
                            ),
                        )
                    } else {
                        put("media_unreadable", 1)
                    }
                }
                Log.i(
                    DBG,
                    "mediaLine pkg=$packageName captured=" +
                        (if (captured != null) captured.kind else "none"),
                )
                MessageSpool.append(this, line)
            } catch (e: Exception) {
                // Same rule as the probe: nothing throws off this thread.
                Log.w(DBG, "mediaLine pkg=$packageName failed: " + e.javaClass.simpleName)
            }
        }
    }

    /**
     * Caches the notification's own reply action, if it has one. Returns
     * whether a reply could be delivered right now.
     */
    private fun rememberReply(
        channel: String,
        conversationId: String,
        sbn: StatusBarNotification,
    ): Boolean {
        val actions = sbn.notification.actions ?: return false
        for (action in actions) {
            val inputs = action.remoteInputs ?: continue
            val free = inputs.firstOrNull { it.allowFreeFormInput } ?: continue
            val intent = action.actionIntent ?: continue
            ReplyRegistry.remember(
                channel = channel,
                conversationId = conversationId,
                packageName = sbn.packageName,
                intent = intent,
                remoteInput = free,
                extraInputs = inputs,
            )
            return true
        }
        return false
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (!ChatPackages.shouldCapture(this, sbn.packageName)) return
        val channel = ChatPackages.channelFor(sbn.packageName) ?: return
        val title = sbn.notification.extras
            .getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()
            ?: return
        // The reply action died with the notification. Dropping it here is
        // what makes `can_reply` mean "right now" rather than "at some point".
        ReplyRegistry.forget(channel, title.lowercase())
    }

    private data class Entry(
        val text: String?,
        val sender: String?,
        val time: Long,
        /** The one media slot this `MessagingStyle` message advertises, if
         *  any. Read with [NotificationMedia.messageCandidate] from the
         *  same bundle as the text, so photo and caption can never be
         *  matched up wrong the way a per-notification list could. */
        val media: NotificationMedia.Candidate?,
    )

    /**
     * Parses `EXTRA_MESSAGES` with framework APIs only.
     *
     * `NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification`
     * would do this in one line and is deliberately not used: it lives in
     * androidx.core, which this module only has transitively through whatever
     * plugins happen to be in `pubspec.yaml` today. The bundle keys below are
     * stable platform API and cost nothing.
     */
    private fun messageEntries(extras: Bundle): List<Entry> {
        val raw: Array<Parcelable>? = if (Build.VERSION.SDK_INT >= 33) {
            extras.getParcelableArray(Notification.EXTRA_MESSAGES, Parcelable::class.java)
        } else {
            @Suppress("DEPRECATION")
            extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        }
        if (raw == null) return emptyList()

        val entries = mutableListOf<Entry>()
        for (item in raw) {
            val bundle = item as? Bundle ?: continue
            val text = bundle.getCharSequence(MSG_TEXT)?.toString()
            val person: Person? = if (Build.VERSION.SDK_INT >= 33) {
                bundle.getParcelable(MSG_SENDER_PERSON, Person::class.java)
            } else {
                @Suppress("DEPRECATION")
                bundle.getParcelable(MSG_SENDER_PERSON) as? Person
            }
            val sender = person?.name?.toString()
                ?: bundle.getCharSequence(MSG_SENDER)?.toString()
            entries.add(
                Entry(
                    text = text,
                    sender = sender?.trim()?.takeIf { it.isNotEmpty() },
                    time = bundle.getLong(MSG_TIME, 0L),
                    media = NotificationMedia.messageCandidate(bundle),
                ),
            )
        }
        return entries
    }

    private fun spool(
        channel: String,
        packageName: String,
        conversationId: String,
        title: String,
        isGroup: Boolean,
        sender: String?,
        body: String,
        sentAt: Long,
        canReply: Boolean,
    ) {
        val entry = JSONObject().apply {
            put("channel", channel)
            put("package", packageName)
            put("conversation_id", conversationId)
            put("conversation_title", title)
            put("is_group", isGroup)
            if (sender != null) put("sender", sender)
            put("body", body)
            put("sent_at", sentAt)
            put("can_reply", canReply)
        }
        MessageSpool.append(this, entry)
    }
}

/** Framework-only check that this build's listener is enabled. */
object NotificationAccess {
    private const val SETTING = "enabled_notification_listeners"

    fun isGranted(context: android.content.Context): Boolean {
        val enabled = android.provider.Settings.Secure.getString(
            context.contentResolver,
            SETTING,
        ) ?: return false
        // The setting is a colon-separated list of flattened ComponentNames.
        // Matching on the package alone would report true for a *different*
        // component of this app, so the component is compared properly.
        val expected = android.content.ComponentName(
            context,
            ExaNotificationListener::class.java,
        )
        return enabled.split(':').any {
            val parsed = android.content.ComponentName.unflattenFromString(it.trim())
            parsed == expected
        }
    }

    /** Kicks the service so a fresh grant takes effect without a reboot. */
    fun rebind(context: android.content.Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                NotificationListenerService.requestRebind(
                    android.content.ComponentName(
                        context,
                        ExaNotificationListener::class.java,
                    ),
                )
            } catch (e: Exception) {
                // Best effort: the system binds it on its own schedule too.
            }
        }
    }
}

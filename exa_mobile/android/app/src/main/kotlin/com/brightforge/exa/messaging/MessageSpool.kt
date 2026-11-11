package com.brightforge.exa.messaging

import android.content.Context
import android.util.Log
import java.io.File
import org.json.JSONObject

/**
 * Append-only handover file between the notification listener and Dart.
 *
 * **Why a file and not a platform channel.** The listener is started by the
 * system whenever it likes, routinely with no Activity and no Flutter engine
 * alive, so there is often nothing on the other end of a channel to call.
 * Worse, the code that *drains* this runs in the WorkManager isolate, whose
 * engine never sees the MethodChannels `MainActivity` registers — a channel
 * would work in the foreground and silently do nothing in the background,
 * which is the half of this feature that matters.
 *
 * A file in `filesDir` is reachable from every isolate (path_provider's
 * `getApplicationSupportDirectory()` is exactly this directory), survives the
 * process dying between a message arriving and Exa waking up, and needs no
 * engine at all.
 *
 * **Why it is not SQLite.** The Dart side owns the schema and every write
 * goes through a repository so provenance and dedupe happen in one place. A
 * second writer in Kotlin would be a second migration path.
 *
 * One JSON object per line, UTF-8. A malformed line is skipped by the reader
 * rather than failing the drain: losing one captured message is a far better
 * outcome than a parse error that stops the queue moving forever.
 *
 * **This object never deletes a media file.** Media lines reference sidecar
 * files under `exa_media/incoming/`, and [trim] and [clear] above touch only
 * this JSONL - deliberately. The moment a sidecar is named by a spool line,
 * Dart is its only owner: a row may already reference the same file from an
 * earlier line, and a trim here would silently destroy a photo behind a
 * live message. Kotlin creates files (and removes only its own `.part`
 * scratch); Dart unlinks them, and only when the last row naming a file is
 * gone. Keep it that way.
 */
object MessageSpool {
    private const val TAG = "ExaMessageSpool"
    const val FILE_NAME = "exa_message_spool.jsonl"

    /**
     * Above this the oldest half is dropped. A phone left alone in a busy
     * group chat would otherwise grow this file without bound; the newest
     * messages are the ones worth keeping, and [KEY_DROPPED] means the loss
     * is reported rather than silent.
     */
    private const val MAX_BYTES = 512 * 1024L

    const val KEY_DROPPED = "spool_dropped"

    private val lock = Any()

    private fun file(context: Context) = File(context.filesDir, FILE_NAME)

    /**
     * Appends one captured message. Never throws: this runs inside
     * `onNotificationPosted`, and an exception there is a listener the system
     * may stop calling.
     */
    fun append(context: Context, entry: JSONObject) {
        synchronized(lock) {
            try {
                val target = file(context)
                // The handle is opened and closed per message rather than
                // held: Dart drains by renaming this file, and a long-lived
                // append stream would keep writing into the renamed inode.
                target.appendText(entry.toString() + "\n")
                if (target.length() > MAX_BYTES) trim(context, target)
            } catch (e: Exception) {
                Log.w(TAG, "Could not spool a captured message", e)
            }
        }
    }

    /** Keeps the newest half and counts what went. */
    private fun trim(context: Context, target: File) {
        try {
            val lines = target.readLines()
            val keep = lines.subList(lines.size / 2, lines.size)
            target.writeText(keep.joinToString("\n", postfix = "\n"))
            val prefs =
                context.getSharedPreferences(ChatPackages.PREFS, Context.MODE_PRIVATE)
            val dropped = prefs.getInt(KEY_DROPPED, 0) + (lines.size - keep.size)
            prefs.edit().putInt(KEY_DROPPED, dropped).apply()
            Log.w(TAG, "Spool over ${MAX_BYTES}B; dropped ${lines.size - keep.size}")
        } catch (e: Exception) {
            Log.w(TAG, "Could not trim the spool; truncating", e)
            target.writeText("")
        }
    }

    /** Queue depth, for the settings screen. */
    fun pendingCount(context: Context): Int = synchronized(lock) {
        try {
            val target = file(context)
            if (!target.exists()) 0 else target.readLines().count { it.isNotBlank() }
        } catch (e: Exception) {
            0
        }
    }

    fun clear(context: Context) {
        synchronized(lock) {
            try {
                file(context).delete()
            } catch (e: Exception) {
                Log.w(TAG, "Could not clear the spool", e)
            }
        }
    }
}

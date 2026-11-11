package com.brightforge.exa.messaging

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import java.util.zip.ZipInputStream

/**
 * Turns a share / "process text" intent into a plain map for Dart.
 *
 * This is the deliberate half of the feature: the user pointing at one thing
 * and handing it to Exa. It covers what the notification listener cannot —
 * a message from before capture was enabled, a whole chat's exported history,
 * an email body — and it is the only path that needs no special access at all.
 *
 * Three shapes arrive here:
 *  - `ACTION_SEND` with text: a forwarded chat message, or an email body
 *    shared from a mail client (which also supplies a subject).
 *  - `ACTION_SEND` with a stream: a WhatsApp chat export, either the bare
 *    `.txt` or the `.zip` produced by "include media".
 *  - `ACTION_PROCESS_TEXT`: text selected anywhere in the OS. Useful in Gmail
 *    and browsers; it does **not** appear for WhatsApp message bubbles, which
 *    are selected whole rather than as text — which is exactly why the share
 *    and notification paths both exist.
 */
object SharedIntake {
    private const val TAG = "ExaSharedIntake"

    /**
     * Bound on an imported export. A year of a busy group chat is a few
     * hundred KB of text; anything past this is not a chat log, and reading
     * it would be an out-of-memory crash on the main thread.
     */
    private const val MAX_TEXT_BYTES = 4 * 1024 * 1024

    fun parse(activity: Activity, intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND -> parseSend(activity, intent)
            Intent.ACTION_PROCESS_TEXT -> parseProcessText(intent)
            else -> null
        }
    }

    private fun parseProcessText(intent: Intent): Map<String, Any?>? {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
            ?.toString()
            ?.trim()
            ?: return null
        if (text.isEmpty()) return null
        return mapOf(
            "action" to "process_text",
            "text" to text,
            "readonly" to !intent.getBooleanExtra(
                Intent.EXTRA_PROCESS_TEXT_READONLY,
                false,
            ),
        )
    }

    private fun parseSend(activity: Activity, intent: Intent): Map<String, Any?>? {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim()
        val stream: Uri? = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }

        var fileName: String? = null
        var fileText: String? = null
        if (stream != null) {
            fileName = displayName(activity, stream)
            fileText = readText(activity, stream, fileName)
        }

        if (text.isNullOrEmpty() && fileText.isNullOrEmpty()) return null

        return mapOf(
            "action" to "send",
            "text" to text,
            "subject" to subject,
            "file_name" to fileName,
            "file_text" to fileText,
            // android-app://com.whatsapp -> com.whatsapp. Lets a shared
            // message be filed under the channel it came from instead of an
            // "unknown" bucket the user then has to explain to Exa.
            "source_package" to activity.referrer?.host,
        )
    }

    private fun displayName(activity: Activity, uri: Uri): String? = try {
        activity.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
    } catch (e: Exception) {
        Log.w(TAG, "Could not read the shared file's name", e)
        null
    }

    /**
     * Reads a shared `.txt`, or the first `.txt` inside a shared `.zip`.
     *
     * WhatsApp's "export chat" produces a bare `.txt` without media and a
     * `.zip` containing `_chat.txt` with it, and a user who exported with
     * media should not be told to go back and do it again.
     */
    private fun readText(activity: Activity, uri: Uri, name: String?): String? {
        val lower = (name ?: "").lowercase()
        val isZip = lower.endsWith(".zip") ||
            activity.contentResolver.getType(uri) == "application/zip"
        return try {
            activity.contentResolver.openInputStream(uri)?.use { input ->
                if (isZip) {
                    ZipInputStream(input).use { zip ->
                        var entry = zip.nextEntry
                        while (entry != null) {
                            if (!entry.isDirectory &&
                                entry.name.lowercase().endsWith(".txt")
                            ) {
                                return@use zip.readBounded()
                            }
                            entry = zip.nextEntry
                        }
                        null
                    }
                } else {
                    input.readBounded()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not read the shared file", e)
            null
        }
    }

    private fun java.io.InputStream.readBounded(): String {
        val buffer = ByteArray(64 * 1024)
        val out = java.io.ByteArrayOutputStream()
        var total = 0
        while (true) {
            val read = read(buffer)
            if (read <= 0) break
            val room = MAX_TEXT_BYTES - total
            if (room <= 0) break
            out.write(buffer, 0, minOf(read, room))
            total += read
        }
        return out.toString("UTF-8")
    }
}

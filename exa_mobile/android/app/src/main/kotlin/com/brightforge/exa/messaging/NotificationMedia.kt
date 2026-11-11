package com.brightforge.exa.messaging

import android.content.ContentResolver
import android.content.Context
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Bundle
import android.os.Parcelable
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.LinkedHashMap

/**
 * Where message media is identified and proven reachable.
 *
 * This exists because of a question the whole media feature turns on: a
 * `MessagingStyle` notification advertises its photo or voice note as a
 * content URI that belongs to the *posting app's private provider*, and a
 * NotificationListenerService is not automatically allowed to open it. Until
 * the spike ran per app, "Exa can attach your WhatsApp photos" was a promise
 * nobody had tested; the pipeline now built on top of it ([capture]) keeps
 * [probe]'s per-app answer as its gate and its cache, and a URI that returns
 * SecurityException degrades to an honest could-not-read note, never to a
 * silent loss.
 *
 * What it deliberately is not:
 *  - **A spool writer.** It copies bytes to the media directory and returns
 *    metadata; the listener decides what to append to the spool. Bytes never
 *    enter any spool line - the file is a 512 KB append-only buffer and a
 *    single base64 photo would evict half the waiting messages to arrive.
 *  - **Not a logger.** Content URIs carry signed, sometimes expiring tokens,
 *    so this object takes the URI in and returns only a scheme, a mime type,
 *    a byte count and a failure class. Keep it that way: no Log here, and no
 *    URI-typed field leaves [ProbeResult]. (The caller's log lines follow the
 *    same rule; [media_probe_test.dart] pins both.)
 *
 * Only `content` URIs are ever opened. A provider handing the notification a
 * `file:` path would be asking Exa to read arbitrary app-private storage,
 * which the allowlist was never meant to cover.
 *
 * ### File ownership
 *
 * [capture] creates files and renames its own `.part` scratch into place;
 * the only file it ever *deletes* is its own scratch. Dart owns the lifetime
 * of every sidecar this hands to a spool line - an unconditional unlink
 * here could destroy a photo that a stored message still references.
 */
object NotificationMedia {

        /**
         * Enough to prove a stream opens and carries bytes, small enough
         * that a big voice note costs nothing. One constant on purpose: two
         * caps drift, and a probe reading more than this is streaming media
         * under a name that says otherwise.
         */
        const val MAX_PROBE_BYTES = 32 * 1024

        /**
         * The mime types Exa copies, and the only ones it copies. An app
         * that advertises `application/pdf` or `video/mp4` gets the message
         * stored with a could-not-read note instead: every downstream
         * promise (the size caps, the note wording, the provider behaviour)
         * is made about images and audio, and a silent fallback for other
         * kinds would make those promises lies.
         */
        val ALLOWED_IMAGE_MIMES = setOf(
            "image/jpeg",
            "image/png",
            "image/webp",
            "image/gif",
        )
        val ALLOWED_AUDIO_MIMES = setOf(
            "audio/ogg",
            "audio/ogg;codecs=opus", // what WhatsApp voice notes declare
            "audio/mpeg",
            "audio/mp4",
            "audio/amr",
            "audio/aac",
        )

        /**
         * Declared-length ceilings, checked **before** a byte is read.
         * 3 MiB for images is what keeps the base64 staging inside a vision
         * provider's per-image limit; 8 MiB covers a long voice note while
         * staying far below the spool buffer's own cap. A provider that
         * lies about its length is caught again by the copy loop, which
         * aborts a stream longer than the kind's ceiling.
         */
        const val MAX_IMAGE_BYTES = 3 * 1024 * 1024
        const val MAX_AUDIO_BYTES = 8 * 1024 * 1024

        /** Media directory, relative to filesDir - the Dart reader's
         *  `exa_media/incoming` resolved against the spool's directory.
         *  The two strings are the whole contract between the languages. */
        const val MEDIA_DIR = "exa_media"
        const val MEDIA_INCOMING_DIR = "incoming"

        /**
         * Length of the content hash that names every sidecar: the leading
         * 16 bytes of SHA-256, as 32 lowercase hex characters (128 bits -
         * far past what deduping device-local photos needs). Every other
         * site in the pipeline is pinned to this exact number - the spool
         * parser's `^[0-9a-f]{32}$`, `sidecarPattern` in the Dart
         * repository, its `sha256Of` (which truncates the digest the same
         * way), and the DB rows - so this file may not be the one place
         * that emits the full 64. Getting it wrong is the quietest possible
         * break: Dart would reject every captured photo as a bad entry, so
         * the media is never stored *and* never deleted, because no row
         * ever references the file for the orphan sweep to collect.
         * Changing this number means changing all four sites at once;
         * [media_capture_test.dart] pins both sides.
         */
        const val CONTENT_HASH_HEX_CHARS = 32

        /**
         * `MessagingStyle` re-posts every recent message on every new
         * arrival, so the same URIs arrive over and over. Re-opening them
         * each time multiplies provider reads and log lines for no new
         * information; the answer for a given package+URI does not change
         * within a notification's lifetime, so one probe answers all the
         * re-posts.
         */
        const val MAX_CACHE_ENTRIES = 200

        /** The spool line and later media rows carry at most this many items per message. */
        const val MAX_MEDIA_ITEMS_PER_MESSAGE = 4

        /**
         * Bundle keys inside one `Notification.EXTRA_MESSAGES` entry. These
         * are the platform's `MessagingStyle.Message.toBundle` keys ("uri"
         * holds the data URI **as a String**, "type" its mime) - stable
         * public API that [ExaNotificationListener] also relies on for
         * text/sender/time. Typo-prone, which is why [mediaCandidates] is a
         * separate function pinned by [NotificationMediaTest].
         */
        private const val MSG_MIME_TYPE = "type"
        private const val MSG_URI = "uri"

    /**
     * Which slot of the notification a candidate came from. The distinction
     * is load-bearing: only a per-message `uri` is this message's media.
     * `Notification.EXTRA_PICTURE` is the notification's *big picture* - on
     * real devices that is often the conversation avatar or the first image
     * in the shade, not the current message's attachment - so it is recorded
     * as `NOTIFICATION_PICTURE` and must never be attached to a message.
     */
    enum class MediaOrigin {
        MESSAGE_ATTACHMENT,
        NOTIFICATION_PICTURE,
        ;

        /** The lowercase wire value shared by the report, the tile and Dart. */
        fun label(): String = name.lowercase()
    }

    /**
     * Why opening a media URI did not cleanly work. Exactly one of these is
     * ever stored or logged; it is the whole answer, because the URI itself
     * is never stored or logged.
     */
    enum class Failure {
        OK,
        SECURITY,
        NOT_FOUND,
        EMPTY_STREAM,
        NULL_URI,
        UNSUPPORTED_SCHEME,
        ;

        /** The lowercase wire value shared by the report, the tile and Dart. */
        fun label(): String = name.lowercase()
    }

    /** One media slot advertised by a notification, before any reading. */
    data class Candidate(
        val origin: MediaOrigin,
        val mimeType: String?,
        val uri: Uri?,
    )

    /** The outcome of one bounded read. Note the absence of any URI field. */
    data class ProbeResult(
        val scheme: String?,
        val mimeType: String?,
        val bytesRead: Int,
        val failure: Failure,
    )

    /**
     * `package|uri` -> probe result. Access-ordered [LinkedHashMap] with
     * [removeEldestEntry] is the standard no-import LRU; the listener's
     * probe worker is the only caller and it is a single thread, but the
     * lock keeps that a fact rather than a convention.
     */
    private val cache = object : LinkedHashMap<String, ProbeResult>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, ProbeResult>): Boolean =
            size > MAX_CACHE_ENTRIES
    }

    /**
     * `package|uri` -> the capture that was already performed (null: this
     * URI is known-unreadable). Re-posts of a photo already on disk must
     * cost no provider read *and* no second copy: the sidecar
     * content-addresses itself, so the answer for a URI is forever, and
     * answering it from memory is the whole point.
     */
    private val captureCache =
        object : LinkedHashMap<String, CapturedMedia?>(32, 0.75f, true) {
            override fun removeEldestEntry(
                eldest: Map.Entry<String, CapturedMedia?>,
            ): Boolean = size > MAX_CACHE_ENTRIES
        }

    /** One successfully captured sidecar, ready to be described in a
     *  spool line. [file] is the *basename only* - a spool line never
     *  carries a path a hostile reader could follow, and Dart roots the
     *  name in the media directory itself. */
    data class CapturedMedia(
        val kind: String,
        val mimeType: String?,
        val file: String,
        val sizeBytes: Long,
        val contentHash: String,
        val origin: MediaOrigin,
    )

    /** Mime -> kind, or null. Parameters (`audio/ogg; codecs=opus`) are
     *  matched on the normalised whole string, which is exactly how the
     *  allowlist above is written - WhatsApp's voice notes declare the
     *  codec in the mime and would otherwise be rejected as `audio/ogg`. */
    fun kindOf(mimeType: String?): String? {
        val normalised = mimeType?.trim()?.lowercase()?.replace(" ", "") ?: return null
        return when {
            normalised in ALLOWED_IMAGE_MIMES -> "image"
            normalised in ALLOWED_AUDIO_MIMES -> "audio"
            else -> null
        }
    }

    /**
     * Copies [candidate]'s bytes into the media directory as a
     * content-addressed sidecar, or returns null having refused or failed.
     *
     * Every rejection happens **before** opening the stream - scheme,
     * origin, mime, declared length - because the cost of a refusal is one
     * could-not-read note, while the cost of a late refusal is a
     * half-written file and a provider call that hung the worker.
     *
     * `NOTIFICATION_PICTURE` candidates are never copied: the big picture
     * is the conversation avatar on real devices (see [MediaOrigin]), so
     * persisting it as this message's media would attach somebody's face to
     * the wrong text. It stays probe-only, forever, by design.
     */
    fun capture(
        context: Context,
        packageName: String,
        candidate: Candidate,
    ): CapturedMedia? {
        val uri = candidate.uri ?: return null
        if (candidate.origin != MediaOrigin.MESSAGE_ATTACHMENT) return null
        if (uri.scheme != "content") return null

        val kind = kindOf(candidate.mimeType) ?: return null
        val ceiling = if (kind == "image") MAX_IMAGE_BYTES else MAX_AUDIO_BYTES

        val key = "$packageName|${uri.toString()}"
        val known = synchronized(captureCache) { captureCache[key] }
        if (known != null) return known

        // Ask the provider how long this is, and refuse oversized media
        // before reading it: a 200 MB "voice note" must not become 8 MiB of
        // I/O and a torn file. Unknown length (-1/0) is allowed through,
        // because some providers omit it, and the copy loop enforces the
        // ceiling on what it actually receives.
        try {
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                val declared = afd.length
                if (declared > ceiling) {
                    synchronized(captureCache) { captureCache[key] = null }
                    return null
                }
            }
        } catch (e: SecurityException) {
            synchronized(captureCache) { captureCache[key] = null }
            return null
        } catch (e: Exception) {
            // A missing descriptor is not itself a refusal; the stream
            // below decides.
        }

        val dir = File(File(context.filesDir, MEDIA_DIR), MEDIA_INCOMING_DIR)
        if (!dir.exists() && !dir.mkdirs()) return null

        var part: File? = null
        try {
            // Copy to a scratch name while hashing, so a crash, an
            // oversize-abort or an empty stream leaves a `.part` nobody
            // references, never a complete-looking sidecar with bad bytes.
            part = File(dir, "capture-${System.nanoTime()}.part")
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            context.contentResolver.openInputStream(uri)?.use { input ->
                part!!.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                        total += read
                        if (total > ceiling) {
                            // The provider understated (or omitted) the
                            // length: stop rather than fill storage.
                            throw FileNotFoundException("media over cap")
                        }
                    }
                }
            } ?: return null
            if (total == 0L) return null

            val hex = truncatedHex(digest)
            val extension = extensionFor(candidate.mimeType, kind)
            val finalName = "$hex.$extension"
            val finalFile = File(dir, finalName)
            if (finalFile.exists() && finalFile.length() == total) {
                // Same bytes already on disk (the same photo re-posted, or
                // forwarded between chats): keep one file, skip the copy.
                part.delete()
                val captured = CapturedMedia(
                    kind, candidate.mimeType, finalName, total, hex, candidate.origin,
                )
                synchronized(captureCache) { captureCache[key] = captured }
                return captured
            }
            if (!part.renameTo(finalFile)) return null
            part = null // renamed: nothing left to clean up
            val captured = CapturedMedia(
                kind, candidate.mimeType, finalName, total, hex, candidate.origin,
            )
            synchronized(captureCache) { captureCache[key] = captured }
            return captured
        } catch (e: Exception) {
            // SecurityException, FileNotFoundException, over-cap abort,
            // disk full: all the same answer, and none of it may escape to
            // the worker - an uncaught throw there is a crash while Exa was
            // merely copying a photo.
            return null
        } finally {
            // The only unlink this object ever performs: its own scratch.
            try {
                part?.delete()
            } catch (e: Exception) {
                // Best effort; a stray capture-*.part is invisible to Dart
                // (it never matches the sidecar name pattern), so nothing
                // can ever trust it, and the OS clears cache-adjacent files
                // on uninstall.
            }
        }
    }

    /**
     * The content hash for one finished stream: lowercase hex of the
     * SHA-256, truncated to [CONTENT_HASH_HEX_CHARS] characters. That
     * truncation is not decoration - it is the *same* derivation Dart's
     * `InboundMediaRepository.sha256Of` performs, and the only reason the
     * byte-level re-check on the Dart side can ever match what was copied
     * here. An untruncated value passes through `capture` unnoticed and
     * fails Dart's pattern silently, stranding the file forever.
     */
    private fun truncatedHex(digest: MessageDigest): String =
        digest.digest()
            .joinToString("") { "%02x".format(it) }
            .substring(0, CONTENT_HASH_HEX_CHARS)

    private fun extensionFor(mimeType: String?, kind: String): String {
        val normalised = mimeType?.trim()?.lowercase()?.replace(" ", "")
        return when (normalised) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "audio/ogg", "audio/ogg;codecs=opus" -> "ogg"
            "audio/mpeg" -> "mp3"
            "audio/mp4" -> "m4a"
            "audio/amr" -> "amr"
            "audio/aac" -> "aac"
            else -> if (kind == "image") "bin" else "aud"
        }
    }

    /**
     * The one media slot advertised by a single `EXTRA_MESSAGES` bundle, or
     * null when that message has no media. One entry point for both passes
     * so the probe and the capture can never disagree about which bundle
     * keys mean what.
     *
     * A message with a mime but no URI still yields a (null-URI) candidate:
     * "this photo message advertised no readable target" is itself a fact
     * the per-app matrix has to show, or the spike reports fewer media items
     * than the app actually posted.
     */
    fun messageCandidate(bundle: Bundle): Candidate? {
        val mimeType = bundle.getString(MSG_MIME_TYPE)?.trim()?.takeIf { it.isNotEmpty() }
        val uriString = bundle.getString(MSG_URI)?.trim()?.takeIf { it.isNotEmpty() }
        if (mimeType == null && uriString == null) return null
        return Candidate(
            origin = MediaOrigin.MESSAGE_ATTACHMENT,
            mimeType = mimeType,
            uri = uriString?.let { Uri.parse(it) },
        )
    }

    /**
     * Turns the raw `EXTRA_MESSAGES` bundles plus the notification's big
     * picture into media candidates, capped at
     * [MAX_MEDIA_ITEMS_PER_MESSAGE] per message.
     */
    fun mediaCandidates(messages: Array<out Parcelable>?, bigPicture: Uri?): List<Candidate> {
        val out = mutableListOf<Candidate>()
        if (messages != null) {
            for (item in messages) {
                if (out.size >= MAX_MEDIA_ITEMS_PER_MESSAGE) break
                val bundle = item as? Bundle ?: continue
                val candidate = messageCandidate(bundle) ?: continue
                out.add(candidate)
            }
        }
        if (bigPicture != null && out.size < MAX_MEDIA_ITEMS_PER_MESSAGE) {
            out.add(
                Candidate(
                    origin = MediaOrigin.NOTIFICATION_PICTURE,
                    mimeType = null,
                    uri = bigPicture,
                ),
            )
        }
        return out
    }

    /**
     * Proves [candidate]'s URI opens, at most [MAX_PROBE_BYTES] deep, and
     * caches the answer for the rest of the re-post storm. Never throws.
     */
    fun probe(resolver: ContentResolver, packageName: String, candidate: Candidate): ProbeResult {
        val key = "$packageName|${candidate.uri?.toString()}"
        val cached = synchronized(cache) { cache[key] }
        if (cached != null) return cached
        val result = probeUncached(resolver, candidate)
        synchronized(cache) { cache[key] = result }
        return result
    }

    private fun probeUncached(resolver: ContentResolver, candidate: Candidate): ProbeResult {
        val uri = candidate.uri
            ?: return ProbeResult(null, candidate.mimeType, 0, Failure.NULL_URI)
        val scheme = uri.scheme
        if (scheme != "content") {
            // Deliberately not opened: see the class comment.
            return ProbeResult(scheme, candidate.mimeType, 0, Failure.UNSUPPORTED_SCHEME)
        }

        var descriptor: AssetFileDescriptor? = null
        var input: InputStream? = null
        try {
            // The declared length is what a later capture stage would size-
            // check before copying; the probe asks for it the same way -
            // openAssetFileDescriptor - because an app that blocks *that*
            // while allowing the stream (or the reverse) is exactly the
            // per-app difference this spike exists to find. A null
            // descriptor is normal, not a failure: the stream decides.
            descriptor = resolver.openAssetFileDescriptor(uri, "r")
            input = resolver.openInputStream(uri)
                ?: return ProbeResult(scheme, candidate.mimeType, 0, Failure.EMPTY_STREAM)

            // One capped fill, no loops past MAX_PROBE_BYTES: a provider
            // that streams forever cannot make this worker read forever.
            val buffer = ByteArray(MAX_PROBE_BYTES)
            var total = 0
            while (total < buffer.size) {
                val read = input.read(buffer, total, buffer.size - total)
                if (read <= 0) break
                total += read
            }
            return ProbeResult(
                scheme = scheme,
                mimeType = candidate.mimeType,
                bytesRead = total,
                failure = if (total == 0) Failure.EMPTY_STREAM else Failure.OK,
            )
        } catch (e: SecurityException) {
            // The provider says no: the case that decides whether Exa can
            // promise this app's media at all.
            return ProbeResult(scheme, candidate.mimeType, 0, Failure.SECURITY)
        } catch (e: FileNotFoundException) {
            // A signed URI whose grant expired between posting and probing
            // lands here too, which is why the cache is per-notification-
            // lifetime and the later capture stage re-probes.
            return ProbeResult(scheme, candidate.mimeType, 0, Failure.NOT_FOUND)
        } catch (e: Exception) {
            // Any other provider failure is still "nothing could be read",
            // and no exception is allowed to leave this thread.
            return ProbeResult(scheme, candidate.mimeType, 0, Failure.NOT_FOUND)
        } finally {
            try {
                input?.close()
            } catch (e: Exception) {
                // Closing is best-effort; the read already answered.
            }
            try {
                descriptor?.close()
            } catch (e: Exception) {
                // Same.
            }
        }
    }
}

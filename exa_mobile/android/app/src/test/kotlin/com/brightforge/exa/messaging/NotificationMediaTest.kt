package com.brightforge.exa.messaging

import android.content.ContentResolver
import android.content.Context
import android.content.res.AssetFileDescriptor
import android.database.ContentObserver
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Parcelable
import android.util.Pair
import androidx.test.core.app.ApplicationProvider
import com.brightforge.exa.messaging.NotificationMedia.Failure
import com.brightforge.exa.messaging.NotificationMedia.MediaOrigin
import java.io.ByteArrayInputStream
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Pins the Extras -> media-candidate mapping and the probe's bounds.
 *
 * These keys and failure branches are stable platform API but typo-prone,
 * and outside this test they are only ever exercised by a real
 * notification on a real phone - the exact combination that hides a typo
 * for a release. (The per-app *behaviour* - whether WhatsApp's provider
 * answers with SecurityException or bytes - cannot be asserted here; that
 * is what the probe matrix reports from real devices.)
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NotificationMediaTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    /**
     * A ContentResolver that counts reads and can be told to fail, so the
     * cache and failure-class tests can *prove* no provider read happened
     * rather than infer it from a return value.
     */
    private class FakeResolver(
        context: Context,
        private val streamBytes: ByteArray = ByteArray(1024) { (it % 251).toByte() },
        private val thrower: (Uri) -> Exception? = { null },
        private val streamFactory: ((Uri) -> InputStream)? = null,
    ) : ContentResolver(context) {
        var inputOpens = 0

        override fun openInputStream(uri: Uri): InputStream? {
            inputOpens++
            thrower(uri)?.let { throw it }
            return streamFactory?.invoke(uri) ?: ByteArrayInputStream(streamBytes)
        }

        override fun openAssetFileDescriptor(
            uri: Uri,
            mode: String,
            signal: CancellationSignal?,
        ): AssetFileDescriptor? = null // Normal for many providers; the stream decides.

        override fun query(
            uri: Uri,
            projection: Array<String?>?,
            selection: String?,
            selectionArgs: Array<String?>?,
            sortOrder: String?,
        ) = null

        override fun insert(uri: Uri, values: Bundle?): Uri? = null

        override fun update(
            uri: Uri,
            values: Bundle?,
            selection: String?,
            selectionArgs: Array<String?>?,
        ) = 0

        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String?>?) = 0

        override fun notifyChange(uri: Uri, observer: ContentObserver?) = Unit

        override fun notifyChange(
            uris: Collection<Uri>,
            observer: ContentObserver?,
            callerIsSyncMarker: Boolean,
            targetUser: Int?,
        ) = Unit

        override fun getType(uri: Uri): String? = null

        override fun openOutputStream(uri: Uri, appendMode: Boolean): OutputStream? = null

        override fun acquireContentProviderClient(
            uri: Uri,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireUnstableContentProviderClient(
            uri: Uri,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireExistingProviderAuthority(
            authority: String,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireProvider(
            uri: Uri,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireExistingProvider(
            uri: Uri,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireUnstableProvider(
            uri: Uri,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireExistingUnstableProvider(
            uri: Uri,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun releaseProvider(client: android.content.ContentProviderClient) = true

        override fun releaseExistingProvider(client: android.content.ContentProviderClient) = true

        override fun releaseUnstableProvider(client: android.content.ContentProviderClient) = true

        override fun releaseProviderWithoutCallingDied(client: android.content.ContentProviderClient) = Unit

        override fun releaseUnstableProvider(
            client: android.content.ContentProviderClient,
            callerIsSyncMarker: Boolean,
        ) = true

        override fun acquireProvider(
            userInfo: android.content.pm.ProviderInfo,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireExistingProvider(
            userInfo: android.content.pm.ProviderInfo,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireUnstableProvider(
            name: String,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireExistingUnstableProvider(
            name: String,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireUnstableProvider(
            userInfo: android.content.pm.ProviderInfo,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun acquireExistingUnstableProvider(
            userInfo: android.content.pm.ProviderInfo,
            stable: Boolean,
        ) = throw UnsupportedOperationException("not part of this probe")

        override fun canonicalize(uri: Uri): Uri? = null

        override fun takePersistableUriPermission(uri: Uri, flags: Int) = Unit

        override fun releasePersistableUriPermission(uri: Uri, flags: Int) = Unit

        override fun getPersistableUriPermissions(flags: Int): List<Pair<String, String>> =
            emptyList()
    }

    private fun messageBundle(mimeType: String?, uri: String?): Bundle =
        Bundle().apply {
            if (mimeType != null) putString("type", mimeType)
            if (uri != null) putString("uri", uri)
            putString("text", "[Photo attached]")
        }

    @Test
    fun `message bundle with mime and uri becomes a message attachment candidate`() {
        val bundle = messageBundle("image/jpeg", "content://media/whatsapp-probe-1")
        val candidates = NotificationMedia.mediaCandidates(arrayOf<Parcelable>(bundle), null)

        assertEquals(1, candidates.size)
        assertEquals(MediaOrigin.MESSAGE_ATTACHMENT, candidates.single().origin)
        assertEquals("image/jpeg", candidates.single().mimeType)
        assertEquals(Uri.parse("content://media/whatsapp-probe-1"), candidates.single().uri)
    }

    @Test
    fun `message advertising media with no uri is kept so the matrix shows it`() {
        val bundle = messageBundle("image/jpeg", null)
        val candidates = NotificationMedia.mediaCandidates(arrayOf<Parcelable>(bundle), null)

        assertEquals(1, candidates.size)
        assertNull(candidates.single().uri)

        val result = NotificationMedia.probe(
            FakeResolver(context),
            "com.whatsapp",
            candidates.single(),
        )
        assertEquals(Failure.NULL_URI, result.failure)
        assertEquals(0, result.bytesRead)
    }

    @Test
    fun `empty declared mime reads back as no mime, not an empty string`() {
        val bundle = messageBundle("", "content://media/whatsapp-probe-2")
        val candidates = NotificationMedia.mediaCandidates(arrayOf<Parcelable>(bundle), null)

        assertEquals(1, candidates.size)
        assertNull(candidates.single().mimeType)
    }

    @Test
    fun `big picture is a notification picture, never the message's attachment`() {
        val bigPicture = Uri.parse("content://media/whatsapp-probe-3")
        val candidates = NotificationMedia.mediaCandidates(null, bigPicture)

        assertEquals(1, candidates.size)
        // The load-bearing line: EXTRA_PICTURE is often the conversation
        // avatar, so mislabelling it as the message's media would attach a
        // stranger's face to the wrong message later.
        assertEquals(MediaOrigin.NOTIFICATION_PICTURE, candidates.single().origin)
        assertEquals(bigPicture, candidates.single().uri)
    }

    @Test
    fun `a second probe of the same package and uri performs no provider read`() {
        val resolver = FakeResolver(context)
        val uri = Uri.parse("content://media/whatsapp-probe-4")
        val candidate = NotificationMedia.Candidate(
            MediaOrigin.MESSAGE_ATTACHMENT,
            "audio/ogg",
            uri,
        )

        val first = NotificationMedia.probe(resolver, "com.whatsapp", candidate)
        assertEquals(Failure.OK, first.failure)
        assertEquals(1, resolver.inputOpens)

        // MessagingStyle re-posts every recent message on every arrival;
        // the cache is what stops that storm multiplying provider reads.
        val second = NotificationMedia.probe(resolver, "com.whatsapp", candidate)
        assertSame(first, second)
        assertEquals(1, resolver.inputOpens)
    }

    @Test
    fun `blocked provider is recorded as blocked, with zero bytes`() {
        val uri = Uri.parse("content://media/whatsapp-probe-5")
        val resolver = FakeResolver(context, thrower = { _ -> SecurityException() })
        val result = NotificationMedia.probe(
            resolver,
            "org.thoughtcrime.securesms",
            NotificationMedia.Candidate(MediaOrigin.MESSAGE_ATTACHMENT, "image/png", uri),
        )
        assertEquals(Failure.SECURITY, result.failure)
        assertEquals(0, result.bytesRead)
        assertEquals("content", result.scheme)
    }

    @Test
    fun `gone provider is recorded as not found`() {
        val uri = Uri.parse("content://media/whatsapp-probe-6")
        val resolver = FakeResolver(context, thrower = { _ -> FileNotFoundException() })
        val result = NotificationMedia.probe(
            resolver,
            "org.telegram.messenger",
            NotificationMedia.Candidate(MediaOrigin.MESSAGE_ATTACHMENT, "image/jpeg", uri),
        )
        assertEquals(Failure.NOT_FOUND, result.failure)
    }

    @Test
    fun `empty stream is distinguishable from a readable one`() {
        val uri = Uri.parse("content://media/whatsapp-probe-7")
        val resolver = FakeResolver(context, streamFactory = { _ -> ByteArrayInputStream(ByteArray(0)) })
        val result = NotificationMedia.probe(
            resolver,
            "com.google.android.apps.messaging",
            NotificationMedia.Candidate(MediaOrigin.MESSAGE_ATTACHMENT, "image/gif", uri),
        )
        assertEquals(Failure.EMPTY_STREAM, result.failure)
        assertEquals(0, result.bytesRead)
    }

    @Test
    fun `a non-content uri is never opened`() {
        val resolver = FakeResolver(context)
        val result = NotificationMedia.probe(
            resolver,
            "com.whatsapp",
            NotificationMedia.Candidate(
                MediaOrigin.MESSAGE_ATTACHMENT,
                "image/png",
                Uri.parse("file:///data/data/com.whatsapp/files/photo.png"),
            ),
        )
        assertEquals(Failure.UNSUPPORTED_SCHEME, result.failure)
        assertEquals(0, resolver.inputOpens)
    }

    @Test
    fun `the probe reads at most its cap from a stream that never ends`() {
        val uri = Uri.parse("content://media/whatsapp-probe-8")
        val endless = object : InputStream() {
            override fun read(): Int = 65 // 'A', forever
        }
        val resolver = FakeResolver(context, streamFactory = { _ -> endless })
        val result = NotificationMedia.probe(
            resolver,
            "com.microsoft.teams",
            NotificationMedia.Candidate(MediaOrigin.MESSAGE_ATTACHMENT, "audio/mpeg", uri),
        )
        assertEquals(Failure.OK, result.failure)
        assertEquals(NotificationMedia.MAX_PROBE_BYTES, result.bytesRead)
    }
}

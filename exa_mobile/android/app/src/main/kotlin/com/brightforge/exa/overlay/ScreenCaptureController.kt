package com.brightforge.exa.overlay

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import java.io.ByteArrayOutputStream

/**
 * Holds the persistent MediaProjection session for screen snippets.
 *
 * Android 14+ constraints honored here:
 * - a [MediaProjection.Callback] must be registered BEFORE createVirtualDisplay
 * - a projection token permits exactly ONE createVirtualDisplay call, so one
 *   ImageReader + one VirtualDisplay live for the whole consent session
 *
 * Battery: while idle the VirtualDisplay surface is detached (no compositing
 * happens at all). A capture attaches the surface, skips the first frame
 * (often stale/black), grabs the second, then detaches again.
 */
class ScreenCaptureController(
    private val context: Context,
    /** Invoked on the main thread whenever readiness flips. */
    private val onStateChanged: (ready: Boolean) -> Unit,
) {
    companion object {
        private const val TAG = "ExaCapture"

        /** Frames are downscaled so the long edge never exceeds this. */
        private const val MAX_LONG_EDGE = 1440

        /**
         * How long to let frames settle before taking the newest one. Long
         * enough for the compositor to redraw what our hidden overlay was
         * covering, short enough not to be felt.
         */
        private const val SETTLE_MS = 350L

        /**
         * When only the (possibly stale) first frame ever arrives - a still
         * screen produces nothing else - take it rather than fail.
         */
        private const val PATIENCE_MS = 1200L

        private const val CAPTURE_TIMEOUT_MS = 4000L
    }

    private val handlerThread = HandlerThread("exa-capture").apply { start() }
    private val handler = Handler(handlerThread.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var readerWidth = 0
    private var readerHeight = 0

    val isReady: Boolean get() = projection != null

    /**
     * Real display size in pixels - the area one captured frame covers, before
     * the [MAX_LONG_EDGE] downscale. Dart needs it to map a selection made in
     * an overlay window (which may be inset from the display) onto the frame.
     */
    fun displaySize(): Pair<Int, Int> {
        val (width, height, _) = screenMetrics()
        return width to height
    }

    /** Adopts a freshly consented projection. */
    fun attach(mediaProjection: MediaProjection) {
        release()
        mediaProjection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                // User stopped via the status-bar chip, locked the screen, or
                // the system reclaimed the session.
                mainHandler.post {
                    if (projection != null) {
                        releaseInternal()
                        onStateChanged(false)
                    }
                }
            }
        }, mainHandler)

        val (width, height, dpi) = screenMetrics()
        readerWidth = width
        readerHeight = height
        imageReader =
            ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        virtualDisplay = mediaProjection.createVirtualDisplay(
            "exa-snippet",
            width,
            height,
            dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            null, // surface stays detached until a capture is requested
            null,
            handler,
        )
        projection = mediaProjection
        onStateChanged(true)
    }

    /**
     * Grabs a single frame as PNG bytes. [onResult] is invoked on the main
     * thread with (png, width, height, errorCode); png is null on failure.
     *
     * Frames only exist when the screen changes. Waiting for a fixed number of
     * them fails on a still screen - which is most screens worth snipping - so
     * this holds the newest frame instead and decides on a clock:
     *
     *  - [SETTLE_MS]: take the newest frame, as long as it is not the very
     *    first one the freshly attached mirror emitted.
     *  - [PATIENCE_MS]: nothing better arrived, so take that first frame after
     *    all. A slightly stale snippet beats no snippet.
     *  - [CAPTURE_TIMEOUT_MS]: no frame at all - a real failure.
     *
     * [onSurfaceAttached] runs on the main thread the moment the mirror starts
     * producing frames, and is where the caller hides whatever must not appear
     * in the shot. Hiding *then* rather than beforehand is what guarantees a
     * second frame exists: a still screen produces nothing on its own, so the
     * hide has to happen while something is listening. It also makes the
     * frame being skipped precisely the one with the overlay still in it.
     */
    fun captureFrame(
        onSurfaceAttached: (() -> Unit)? = null,
        onResult: (ByteArray?, Int, Int, String?) -> Unit,
    ) {
        handler.post {
            val display = virtualDisplay
            val reader = imageReader
            if (projection == null || display == null || reader == null) {
                Log.w(TAG, "captureFrame: no live projection")
                mainHandler.post { onResult(null, 0, 0, "capture_inactive") }
                return@post
            }
            // Rotation / fold changes since the session started.
            val (width, height, dpi) = screenMetrics()
            val activeReader: ImageReader
            if (width != readerWidth || height != readerHeight) {
                reader.close()
                activeReader = ImageReader.newInstance(
                    width, height, PixelFormat.RGBA_8888, 2)
                imageReader = activeReader
                readerWidth = width
                readerHeight = height
                display.resize(width, height, dpi)
            } else {
                activeReader = reader
            }

            // All of this runs on `handler`: the listener, both deadlines and
            // the timeout are posted to it, so the state below needs no lock.
            var settled = false
            var frames = 0
            var newest: Image? = null
            var settleReached = false
            var acceptFirstFrame = false

            // The deadlines below can outlive a release() - the session ends
            // from the status-bar chip, a screen lock or the system reclaiming
            // it - and touching a freed VirtualDisplay throws. Nothing here is
            // worth crashing the service over.
            fun detach() {
                try {
                    display.surface = null
                    activeReader.setOnImageAvailableListener(null, null)
                    newest?.close()
                } catch (e: Throwable) {
                    Log.w(TAG, "captureFrame: detach after release", e)
                }
                newest = null
            }

            /** Encodes the held frame and reports it, if one is usable yet. */
            fun deliver(): Boolean {
                if (settled) return true
                val image = newest ?: return false
                // Only the first frame is suspect, and only until patience
                // runs out.
                if (frames < 2 && !acceptFirstFrame) return false
                settled = true
                newest = null
                val encoded = try {
                    imageToPng(image)
                } catch (e: Throwable) {
                    Log.w(TAG, "captureFrame: encode failed", e)
                    null
                } finally {
                    image.close()
                }
                detach()
                mainHandler.post {
                    if (encoded == null) {
                        onResult(null, 0, 0, "capture_failed")
                    } else {
                        onResult(encoded.bytes, encoded.width, encoded.height, null)
                    }
                }
                return true
            }

            activeReader.setOnImageAvailableListener({ r ->
                val image = r.acquireLatestImage()
                    ?: return@setOnImageAvailableListener
                if (settled) {
                    image.close()
                    return@setOnImageAvailableListener
                }
                // Hold exactly one frame. The reader has two buffers, so the
                // producer always keeps one free and never stalls - which is
                // what lets this keep the NEWEST frame instead of the oldest.
                frames++
                newest?.close()
                newest = image
                if (settleReached) deliver()
            }, handler)

            display.surface = activeReader.surface
            onSurfaceAttached?.let { mainHandler.post(it) }

            handler.postDelayed({
                settleReached = true
                deliver()
            }, SETTLE_MS)

            handler.postDelayed({
                if (!settled) {
                    acceptFirstFrame = true
                    if (deliver()) {
                        Log.i(TAG, "captureFrame: fell back to the first frame")
                    }
                }
            }, PATIENCE_MS)

            handler.postDelayed({
                if (!settled) {
                    settled = true
                    Log.w(TAG,
                        "captureFrame: no frame after ${CAPTURE_TIMEOUT_MS}ms")
                    detach()
                    mainHandler.post { onResult(null, 0, 0, "capture_timeout") }
                }
            }, CAPTURE_TIMEOUT_MS)
        }
    }

    fun release() {
        releaseInternal()
    }

    fun destroy() {
        releaseInternal()
        handlerThread.quitSafely()
    }

    private fun releaseInternal() {
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        try {
            projection?.stop()
        } catch (_: Throwable) {
        }
        projection = null
    }

    private class Encoded(val bytes: ByteArray, val width: Int, val height: Int)

    private fun imageToPng(image: Image): Encoded {
        val width = image.width
        val height = image.height
        val plane = image.planes[0]
        val pixelStride = plane.pixelStride
        val rowPadding = plane.rowStride - pixelStride * width
        var bitmap = Bitmap.createBitmap(
            width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(plane.buffer)
        if (rowPadding != 0) {
            bitmap = Bitmap.createBitmap(bitmap, 0, 0, width, height)
        }
        val longEdge = maxOf(bitmap.width, bitmap.height)
        if (longEdge > MAX_LONG_EDGE) {
            val scale = MAX_LONG_EDGE.toFloat() / longEdge
            bitmap = Bitmap.createScaledBitmap(
                bitmap,
                (bitmap.width * scale).toInt(),
                (bitmap.height * scale).toInt(),
                true,
            )
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return Encoded(out.toByteArray(), bitmap.width, bitmap.height)
    }

    @Suppress("DEPRECATION")
    private fun screenMetrics(): Triple<Int, Int, Int> {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        wm.defaultDisplay.getRealMetrics(metrics)
        return Triple(metrics.widthPixels, metrics.heightPixels, metrics.densityDpi)
    }
}

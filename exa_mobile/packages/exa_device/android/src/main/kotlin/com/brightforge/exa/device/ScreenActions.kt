package com.brightforge.exa.device

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.hardware.display.DisplayManager
import android.os.Build
import android.util.DisplayMetrics
import android.view.Display
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The screen sub-API, called from [ExaDevicePlugin]. Everything routes
 * through the live [ExaAccessibilityService]; when it is not running (the
 * user has not enabled it yet), each call returns a plain "not available"
 * map rather than throwing, so a tool degrades honestly.
 */
object ScreenActions {

    private fun service(): ExaAccessibilityService? = ExaAccessibilityService.instance

    private fun unavailable(): Map<String, Any?> = mapOf(
        "available" to false,
        "reason" to "Exa's accessibility service is off. Enable it in Exa > "
            + "Settings > Device control (or Settings > Accessibility > Exa).",
    )

    private fun notReady(): Map<String, Any?> = mapOf(
        "ok" to false,
        "error" to "Exa's accessibility service is off, so it cannot act on "
            + "the screen. Enable it in Exa > Settings > Device control.",
    )

    fun read(): Map<String, Any?> = service()?.dumpTree() ?: unavailable()

    fun tap(id: Int?, x: Int?, y: Int?): Map<String, Any?> {
        val svc = service() ?: return notReady()
        val ok = when {
            id != null -> svc.tapNode(id)
            x != null && y != null -> svc.tapAt(x, y)
            else -> return mapOf("ok" to false, "error" to "tap needs an element id or x/y.")
        }
        return result(ok, if (id != null) "No element with id $id, or it could not be tapped. Read the screen again." else "The tap did not go through.")
    }

    fun swipe(context: Context, direction: String, x1: Int?, y1: Int?, x2: Int?, y2: Int?): Map<String, Any?> {
        val svc = service() ?: return notReady()
        if (x1 != null && y1 != null && x2 != null && y2 != null) {
            return result(svc.swipe(x1, y1, x2, y2), "The swipe did not go through.")
        }
        val m = screenSize(context)
        val w = m.first
        val h = m.second
        val cx = w / 2
        val cy = h / 2
        val (sx, sy, ex, ey) = when (direction) {
            // Content moves opposite to the finger: to scroll DOWN the page,
            // the finger goes up.
            "down" -> arrayOf(cx, (h * 0.30).toInt(), cx, (h * 0.70).toInt())
            "up" -> arrayOf(cx, (h * 0.70).toInt(), cx, (h * 0.30).toInt())
            "left" -> arrayOf((w * 0.75).toInt(), cy, (w * 0.25).toInt(), cy)
            "right" -> arrayOf((w * 0.25).toInt(), cy, (w * 0.75).toInt(), cy)
            else -> return mapOf("ok" to false, "error" to "direction must be up, down, left or right.")
        }
        return result(svc.swipe(sx, sy, ex, ey), "The swipe did not go through.")
    }

    fun setText(id: Int, text: String): Map<String, Any?> {
        val svc = service() ?: return notReady()
        return result(svc.setText(id, text), "Could not type into element $id - read the screen again and check it is editable.")
    }

    fun global(action: String): Map<String, Any?> {
        val svc = service() ?: return notReady()
        return result(svc.global(action), "The '$action' action is not available.")
    }

    fun openApp(context: Context, pkg: String): Map<String, Any?> {
        val intent = context.packageManager.getLaunchIntentForPackage(pkg)
            ?: return mapOf("ok" to false, "error" to "No app with package '$pkg' is installed, or it has no launcher.")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return try {
            context.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to (e.message ?: "Could not open $pkg."))
        }
    }

    fun screenshot(): Map<String, Any?> {
        val svc = service()
            ?: return mapOf("ok" to false, "error" to "Exa's accessibility service is off, so it cannot take a screenshot.")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return mapOf("ok" to false, "error" to "Screenshots need Android 11 or newer.")
        }
        val done = CountDownLatch(1)
        var bytes: ByteArray? = null
        var width = 0
        var height = 0
        var error: String? = null
        try {
            svc.takeScreenshot(
                Display.DEFAULT_DISPLAY,
                { r -> r.run() },
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(result: AccessibilityService.ScreenshotResult) {
                        try {
                            val bmp = Bitmap.wrapHardwareBuffer(result.hardwareBuffer, result.colorSpace)
                            val software = bmp?.copy(Bitmap.Config.ARGB_8888, false)
                            result.hardwareBuffer.close()
                            bmp?.recycle()
                            if (software == null) {
                                error = "The screenshot buffer could not be read."
                            } else {
                                val scaled = downscale(software)
                                width = scaled.width
                                height = scaled.height
                                val out = ByteArrayOutputStream()
                                scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
                                bytes = out.toByteArray()
                                if (scaled !== software) software.recycle()
                                scaled.recycle()
                            }
                        } catch (e: Exception) {
                            error = e.message ?: "The screenshot could not be encoded."
                        } finally {
                            done.countDown()
                        }
                    }

                    override fun onFailure(code: Int) {
                        error = "The system refused the screenshot (code $code; often a rate limit or a secure screen)."
                        done.countDown()
                    }
                },
            )
        } catch (e: Exception) {
            return mapOf("ok" to false, "error" to (e.message ?: "takeScreenshot failed."))
        }
        done.await(5, TimeUnit.SECONDS)
        val b = bytes
        return if (b != null) {
            mapOf("ok" to true, "bytes" to b, "media_type" to "image/png", "width" to width, "height" to height)
        } else {
            mapOf("ok" to false, "error" to (error ?: "The screenshot timed out."))
        }
    }

    // --- helpers ---------------------------------------------------------

    private fun result(ok: Boolean, failure: String): Map<String, Any?> =
        if (ok) mapOf("ok" to true) else mapOf("ok" to false, "error" to failure)

    /** Downscale so the long edge is at most 1440px, to keep PNGs small. */
    private fun downscale(src: Bitmap): Bitmap {
        val longEdge = maxOf(src.width, src.height)
        if (longEdge <= 1440) return src
        val scale = 1440f / longEdge
        return Bitmap.createScaledBitmap(src, (src.width * scale).toInt(), (src.height * scale).toInt(), true)
    }

    private fun screenSize(context: Context): Pair<Int, Int> {
        return try {
            val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            val display = dm.getDisplay(Display.DEFAULT_DISPLAY)
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            display.getRealMetrics(metrics)
            Pair(metrics.widthPixels, metrics.heightPixels)
        } catch (e: Exception) {
            Pair(1080, 2220)
        }
    }
}


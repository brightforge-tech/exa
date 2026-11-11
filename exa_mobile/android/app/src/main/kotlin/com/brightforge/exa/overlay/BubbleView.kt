package com.brightforge.exa.overlay

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import com.brightforge.exa.R
import kotlin.math.abs

/**
 * The draggable floating Exa orb. Lives in its own TYPE_APPLICATION_OVERLAY
 * window sized exactly to the bubble. A short touch is a tap (opens the fan
 * menu); a drag moves the window freely, persisting the position in the
 * `exa_overlay` prefs so it survives service restarts and reboots.
 */
@SuppressLint("ViewConstructor")
class BubbleView(
    context: Context,
    private val windowManager: WindowManager,
    private val onTap: () -> Unit,
) : FrameLayout(context) {

    companion object {
        private const val BUBBLE_DP = 56
        private const val EDGE_MARGIN_DP = 4
        const val KEY_X = "bubble_x"
        const val KEY_Y = "bubble_y"
    }

    private val prefs =
        context.getSharedPreferences(ExaOverlayService.PREFS, Context.MODE_PRIVATE)

    val windowParams = WindowManager.LayoutParams(
        dp(BUBBLE_DP),
        dp(BUBBLE_DP),
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        x = prefs.getInt(KEY_X, dp(EDGE_MARGIN_DP))
        y = prefs.getInt(KEY_Y, dp(180))
    }

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downRawX = 0f
    private var downRawY = 0f
    private var startX = 0
    private var startY = 0
    private var dragging = false

    init {
        background = context.getDrawable(R.drawable.overlay_bubble_bg)
        addView(
            ImageView(context).apply {
                setImageResource(R.drawable.ic_launcher_foreground)
                scaleType = ImageView.ScaleType.FIT_CENTER
                contentDescription = "Exa"
            },
            LayoutParams(dp(42), dp(42), Gravity.CENTER),
        )
        isClickable = true
    }

    /** Center of the bubble in screen coordinates, for fan-menu placement. */
    fun centerX(): Int = windowParams.x + windowParams.width / 2
    fun centerY(): Int = windowParams.y + windowParams.height / 2

    fun resetPosition() {
        windowParams.x = dp(EDGE_MARGIN_DP)
        windowParams.y = dp(180)
        persistPosition()
        safeUpdate()
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downRawX = event.rawX
                downRawY = event.rawY
                startX = windowParams.x
                startY = windowParams.y
                dragging = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downRawX
                val dy = event.rawY - downRawY
                if (!dragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                    dragging = true
                }
                if (dragging) {
                    windowParams.x = clampX((startX + dx).toInt())
                    windowParams.y = clampY((startY + dy).toInt())
                    safeUpdate()
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (dragging) {
                    windowParams.x = clampX(windowParams.x)
                    windowParams.y = clampY(windowParams.y)
                    persistPosition()
                    safeUpdate()
                } else if (event.actionMasked == MotionEvent.ACTION_UP) {
                    performClick()
                }
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        onTap()
        return true
    }

    private fun clampX(value: Int): Int {
        val metrics = resources.displayMetrics
        val margin = dp(EDGE_MARGIN_DP)
        return value.coerceIn(margin, metrics.widthPixels - windowParams.width - margin)
    }

    private fun clampY(value: Int): Int {
        val metrics = resources.displayMetrics
        return value.coerceIn(dp(24), metrics.heightPixels - windowParams.height - dp(24))
    }

    private fun persistPosition() {
        prefs.edit().putInt(KEY_X, windowParams.x).putInt(KEY_Y, windowParams.y).apply()
    }

    private fun safeUpdate() {
        // The view can race with removal when the service is stopping.
        if (isAttachedToWindow) {
            try {
                windowManager.updateViewLayout(this, windowParams)
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}

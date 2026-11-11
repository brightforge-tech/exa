package com.brightforge.exa.overlay

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.brightforge.exa.R
import kotlin.math.cos
import kotlin.math.sin

/**
 * Full-screen dimmed overlay that fans the four quick actions out from the
 * bubble: Snippet, Chat, Voice, and Task. Buttons arc away from whichever
 * edge the bubble is snapped to; tapping the dimmed backdrop dismisses.
 */
@SuppressLint("ViewConstructor")
class FanMenuView(
    context: Context,
    private val onAction: (String) -> Unit,
    private val onDismiss: () -> Unit,
) : FrameLayout(context) {

    companion object {
        const val ACTION_SNIPPET = "snippet"
        const val ACTION_CHAT = "chat"

        /**
         * The chat panel, opened already listening: one tap on the bubble,
         * one on Voice, say the thing, and it sends itself when you stop
         * talking. Same Dart panel as [ACTION_CHAT]; the id is what tells it
         * to start the mic.
         */
        const val ACTION_VOICE = "voice"
        const val ACTION_TASK = "task"

        private const val RADIUS_DP = 112
        private const val BUTTON_DP = 52
        private const val ITEM_W_DP = 76
        private const val ITEM_H_DP = 78
    }

    val windowParams = WindowManager.LayoutParams(
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT,
    )

    init {
        setBackgroundColor(0x8A000000.toInt())
        setOnClickListener { onDismiss() }
    }

    /** Lays the four actions out in an arc around the bubble center. */
    fun present(bubbleCx: Int, bubbleCy: Int) {
        removeAllViews()
        val metrics = resources.displayMetrics
        val onLeft = bubbleCx < metrics.widthPixels / 2
        val direction = if (onLeft) 1 else -1
        val radius = dp(RADIUS_DP)

        val actions = listOf(
            Triple(ACTION_SNIPPET, R.drawable.ic_overlay_snippet, "Snippet"),
            Triple(ACTION_CHAT, R.drawable.ic_overlay_chat, "Chat"),
            Triple(ACTION_VOICE, R.drawable.ic_overlay_voice, "Voice"),
            Triple(ACTION_TASK, R.drawable.ic_overlay_task, "Task"),
        )
        // Four buttons on the same radius: 40 degrees apart keeps each
        // 76dp-wide item clear of its neighbours.
        val angles = listOf(-60.0, -20.0, 20.0, 60.0)

        actions.forEachIndexed { index, (action, icon, label) ->
            val radians = Math.toRadians(angles[index])
            val cx = bubbleCx + direction * (radius * cos(radians)).toInt()
            val cy = (bubbleCy + (radius * sin(radians)).toInt())
                .coerceIn(dp(ITEM_H_DP), metrics.heightPixels - dp(ITEM_H_DP))

            val item = buildItem(icon, label) { onAction(action) }
            val lp = LayoutParams(dp(ITEM_W_DP), dp(ITEM_H_DP)).apply {
                leftMargin = (cx - dp(ITEM_W_DP) / 2)
                    .coerceIn(0, metrics.widthPixels - dp(ITEM_W_DP))
                topMargin = cy - dp(ITEM_H_DP) / 2
            }
            addView(item, lp)

            item.scaleX = 0.4f
            item.scaleY = 0.4f
            item.alpha = 0f
            item.animate()
                .scaleX(1f).scaleY(1f).alpha(1f)
                .setStartDelay((index * 30).toLong())
                .setDuration(160)
                .start()
        }
    }

    private fun buildItem(
        iconRes: Int,
        label: String,
        onClick: () -> Unit,
    ): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setOnClickListener { onClick() }

            addView(
                FrameLayout(context).apply {
                    background = context.getDrawable(R.drawable.overlay_fan_button_bg)
                    addView(
                        ImageView(context).apply { setImageResource(iconRes) },
                        LayoutParams(dp(26), dp(26), Gravity.CENTER),
                    )
                },
                LinearLayout.LayoutParams(dp(BUTTON_DP), dp(BUTTON_DP)),
            )
            addView(
                TextView(context).apply {
                    text = label
                    setTextColor(Color.parseColor("#F2EFE9"))
                    textSize = 12f
                    gravity = Gravity.CENTER
                    setShadowLayer(4f, 0f, 1f, Color.parseColor("#99000000"))
                },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(4) },
            )
        }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}

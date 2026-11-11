package com.brightforge.exa.device

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The eyes and hands Exa uses on apps that have no API of their own.
 *
 * It does nothing on its own - it processes no events (Exa is not a
 * screen reader) - and only acts when [ScreenActions] calls it. The live
 * instance is published in [instance] so the plugin, which lives in a
 * different lifecycle, can reach it; it is null whenever the service is not
 * running, and every caller treats that as "not available" rather than
 * crashing.
 *
 * The read is the important half: [dumpTree] flattens the foreground
 * window into a short, indexed list a model can reason about and then act
 * on by index, which is far more reliable for a small model than pixel
 * coordinates or a screenshot.
 */
class ExaAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: ExaAccessibilityService? = null

        /** Widget class -> short role name shown to the model. */
        private fun roleOf(className: CharSequence?): String {
            val c = className?.toString() ?: return ""
            val short = c.substringAfterLast('.')
            return when {
                short.contains("Button") -> "Button"
                short.contains("EditText") -> "EditText"
                short.contains("CheckBox") -> "CheckBox"
                short.contains("Switch") -> "Switch"
                short.contains("RadioButton") -> "RadioButton"
                short.contains("ImageView") -> "Image"
                short.contains("TextView") -> "Text"
                short.contains("RecyclerView") || short.contains("ListView") -> "List"
                else -> short
            }
        }
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // Exa is not a screen reader; it acts on demand, so it ignores the event
    // stream entirely.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    // --- read -----------------------------------------------------------

    /**
     * A flat, indexed view of the foreground window. The index in the
     * returned list is the `id` a follow-up tap/type refers to, so the
     * nodes captured here are held in [lastNodes] until the next read.
     */
    fun dumpTree(): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf(
                "available" to false,
                "reason" to "Nothing is readable on screen right now (a "
                    + "secure window, or the screen is off).",
            )
        val elements = ArrayList<Map<String, Any?>>()
        val nodes = ArrayList<AccessibilityNodeInfo>()
        try {
            collect(root, elements, nodes)
            synchronized(lastNodes) {
                recycleAll(lastNodes)
                lastNodes.clear()
                lastNodes.addAll(nodes)
            }
            return mapOf(
                "available" to true,
                "package" to (root.packageName?.toString() ?: ""),
                "app" to appLabel(root.packageName?.toString()),
                "elements" to elements,
            )
        } finally {
            root.recycle()
        }
    }

    /** Nodes from the last [dumpTree], indexed by the id handed to the model. */
    private val lastNodes = ArrayList<AccessibilityNodeInfo>()

    private fun collect(
        node: AccessibilityNodeInfo?,
        out: ArrayList<Map<String, Any?>>,
        nodes: ArrayList<AccessibilityNodeInfo>,
        depth: Int = 0,
    ) {
        if (node == null || depth > 60 || out.size > 400) return
        val text = node.text?.toString()?.trim().orEmpty()
        val desc = node.contentDescription?.toString()?.trim().orEmpty()
        val interesting = node.isClickable || node.isEditable ||
            node.isCheckable || node.isScrollable ||
            text.isNotEmpty() || desc.isNotEmpty()
        if (interesting && node.isVisibleToUser) {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            if (rect.width() > 0 && rect.height() > 0) {
                val id = nodes.size
                val map = HashMap<String, Any?>()
                map["id"] = id
                if (text.isNotEmpty()) map["text"] = text.take(200)
                if (desc.isNotEmpty()) map["desc"] = desc.take(200)
                map["role"] = roleOf(node.className)
                if (node.isClickable) map["clickable"] = true
                if (node.isEditable) map["editable"] = true
                if (node.isScrollable) map["scrollable"] = true
                if (node.isCheckable) map["checked"] = node.isChecked
                map["bounds"] = listOf(rect.left, rect.top, rect.right, rect.bottom)
                out.add(map)
                nodes.add(AccessibilityNodeInfo.obtain(node))
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i)
            collect(child, out, nodes, depth + 1)
            child?.recycle()
        }
    }

    private fun nodeAt(id: Int): AccessibilityNodeInfo? = synchronized(lastNodes) {
        lastNodes.getOrNull(id)?.let { AccessibilityNodeInfo.obtain(it) }
    }

    // --- act -------------------------------------------------------------

    fun tapNode(id: Int): Boolean {
        val node = nodeAt(id) ?: return false
        try {
            var target: AccessibilityNodeInfo? = node
            // Walk up to the nearest clickable ancestor: the labelled element
            // a person taps is often a child of the actual button.
            var hops = 0
            while (target != null && !target.isClickable && hops < 6) {
                val parent = target.parent
                if (target !== node) target.recycle()
                target = parent
                hops++
            }
            val acting = target ?: node
            val ok = acting.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            if (acting !== node) acting.recycle()
            if (ok) return true
            // Fall back to a gesture at the node's centre.
            val rect = Rect()
            node.getBoundsInScreen(rect)
            return tapAt(rect.centerX(), rect.centerY())
        } finally {
            node.recycle()
        }
    }

    fun tapAt(x: Int, y: Int): Boolean {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        return dispatch(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 60))
                .build(),
        )
    }

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long = 250): Boolean {
        val path = Path().apply {
            moveTo(x1.toFloat(), y1.toFloat())
            lineTo(x2.toFloat(), y2.toFloat())
        }
        return dispatch(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
                .build(),
        )
    }

    fun setText(id: Int, text: String): Boolean {
        val node = nodeAt(id) ?: return false
        try {
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    text,
                )
            }
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        } finally {
            node.recycle()
        }
    }

    fun global(action: String): Boolean {
        val id = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "lock" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) GLOBAL_ACTION_LOCK_SCREEN else return false
            "power" -> GLOBAL_ACTION_POWER_DIALOG
            "split_screen" -> GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN
            else -> return false
        }
        return performGlobalAction(id)
    }

    private fun dispatch(gesture: GestureDescription): Boolean {
        val done = CountDownLatch(1)
        val ok = AtomicBoolean(false)
        val posted = dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(d: GestureDescription?) {
                    ok.set(true); done.countDown()
                }

                override fun onCancelled(d: GestureDescription?) {
                    done.countDown()
                }
            },
            Handler(Looper.getMainLooper()),
        )
        if (!posted) return false
        done.await(3, TimeUnit.SECONDS)
        return ok.get()
    }

    private fun appLabel(pkg: String?): String {
        if (pkg.isNullOrEmpty()) return ""
        return try {
            val pm = packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) {
            pkg
        }
    }

    private fun recycleAll(nodes: List<AccessibilityNodeInfo>) {
        for (n in nodes) {
            try {
                n.recycle()
            } catch (e: Exception) {
                // already recycled
            }
        }
    }
}

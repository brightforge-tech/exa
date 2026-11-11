package com.brightforge.exa.overlay

import android.os.Handler
import android.os.Looper

/**
 * In-process event bus from [ExaOverlayService] to the main Flutter engine's
 * EventChannel (registered in MainActivity). The service and the activity live
 * in the same process, so a simple volatile listener is enough; events are
 * always delivered on the main thread because the EventChannel sink requires
 * it. Events fired while the activity is not listening are dropped - the
 * settings screen re-reads authoritative state on open.
 */
object OverlayEvents {
    const val BUBBLE_ENABLED = "bubbleEnabled"
    const val BUBBLE_DISABLED = "bubbleDisabled"
    const val CAPTURE_READY = "captureReady"
    const val CAPTURE_LOST = "captureLost"

    @Volatile
    private var listener: ((String) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun setListener(l: ((String) -> Unit)?) {
        listener = l
    }

    fun emit(event: String) {
        mainHandler.post { listener?.invoke(event) }
    }
}

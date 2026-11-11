package com.brightforge.exa.overlay

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import com.brightforge.exa.MainActivity
import com.brightforge.exa.R
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground service behind the Exa bubble.
 *
 * Two roles in one service (matching the manifest's
 * `specialUse|mediaProjection` declaration):
 *  - specialUse: hosts the floating bubble + fan menu (plain native views,
 *    zero Flutter cost while collapsed) and, on demand, a second
 *    FlutterEngine running `overlayMain` for the chat / snippet / task
 *    panels. The engine is created lazily and destroyed after 5 minutes of
 *    idle.
 *  - mediaProjection: after per-session consent, holds the persistent screen
 *    capture session ([ScreenCaptureController]) so snippets are instant.
 *    Android 14+ requires startForeground with the mediaProjection type
 *    BEFORE getMediaProjection - see [adoptProjectionResult].
 */
class ExaOverlayService : Service() {

    companion object {
        const val PREFS = "exa_overlay"
        const val KEY_ENABLED = "enabled"

        /**
         * Whether the bubble notification carries Chat / Voice / Snippet
         * actions. They open the app on that feature (unlocking first, from
         * the lock screen), so with this on the notification - which shows on
         * the lock screen - becomes a way to reach Exa without opening it by
         * hand. Off by default: it puts Exa's shortcuts on the lock screen.
         */
        const val KEY_LOCK_SCREEN = "lock_screen"

        const val ACTION_SHOW = "com.brightforge.exa.overlay.SHOW"
        const val ACTION_HIDE = "com.brightforge.exa.overlay.HIDE"
        const val ACTION_PROJECTION_RESULT =
            "com.brightforge.exa.overlay.PROJECTION_RESULT"
        const val ACTION_REQUEST_CONSENT =
            "com.brightforge.exa.overlay.REQUEST_CONSENT"
        const val ACTION_RESET_POSITION =
            "com.brightforge.exa.overlay.RESET_POSITION"
        const val ACTION_REFRESH_NOTIFICATION =
            "com.brightforge.exa.overlay.REFRESH_NOTIFICATION"

        /**
         * Open a panel from outside the fan menu - used for Snippet, which the
         * app hands back to the bubble (`openOverlayPanel`) because it needs
         * the overlay's screen capture. The panel is in [EXTRA_PANEL] (a
         * [FanMenuView] action id).
         */
        const val ACTION_OPEN_PANEL = "com.brightforge.exa.overlay.OPEN_PANEL"
        const val EXTRA_PANEL = "panel"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        /**
         * Panel id for "look at my screen": the chat sheet, which grabs one
         * full-screen frame as soon as it is shown. Not a fan-menu action -
         * it is only ever reached from the chat panel's own button, or from
         * the consent flow returning to it.
         */
        const val PANEL_SCREEN = "screen"

        /**
         * Window modes. `panel` is the 62% bottom sheet; `fullscreen` is the
         * same sheet grown for an open keyboard (Dart asks for it); `selector`
         * is the snippet region picker, the only one that goes edge to edge.
         */
        private const val MODE_PANEL = "panel"
        private const val MODE_FULLSCREEN = "fullscreen"
        private const val MODE_SELECTOR = "selector"

        private const val CHANNEL_ID = "exa_overlay"

        /**
         * A second channel for the same notification when lock-screen access
         * is on. The bubble channel is IMPORTANCE_MIN, which Android keeps off
         * the lock screen entirely; LOW is the quietest level that still shows
         * there (silent, no peek). A channel's importance is the user's to
         * change once created, so this is a separate channel rather than a
         * change to the existing one.
         */
        private const val LOCK_CHANNEL_ID = "exa_overlay_lock"
        private const val NOTIFICATION_ID = 4300
        private const val ENGINE_IDLE_TEARDOWN_MS = 5 * 60 * 1000L
        private const val PANEL_FIRST_FRAME_TIMEOUT_MS = 6 * 1000L
        private const val PANEL_CHANNEL = "com.brightforge.exa/overlay_panel"

        /** Process-wide state the main engine's MethodChannel reads. */
        @Volatile
        var isRunning = false

        @Volatile
        var captureReady = false

        fun captureState(): String = if (captureReady) "ready" else "inactive"
    }

    private lateinit var windowManager: WindowManager
    private lateinit var capture: ScreenCaptureController
    private val mainHandler = Handler(Looper.getMainLooper())

    private var bubble: BubbleView? = null
    private var fanMenu: FanMenuView? = null

    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var panelChannel: MethodChannel? = null
    private var panelParams: WindowManager.LayoutParams? = null
    private var launchPanel = FanMenuView.ACTION_CHAT

    /**
     * Which panel to open once the user grants capture consent, or null when
     * consent was not requested on a panel's behalf. A capture session is
     * released after every frame, so this runs on each capture the user asks
     * for, not just the first.
     */
    private var pendingPanelAfterConsent: String? = null
    private var expectedCaptureStop = false

    private val openPanelAfterConsent = Runnable {
        val panel = pendingPanelAfterConsent
        if (panel != null && capture.isReady) {
            pendingPanelAfterConsent = null
            openPanel(panel)
        }
    }

    /**
     * Safety net for a panel that never paints. A panel window is fully
     * transparent until Dart renders into it, and the snippet window covers
     * the whole display - so if the overlay engine fails to boot (missing
     * entry point, a throw before runApp, ...) the window just sits there
     * swallowing every touch, with no Dart left to answer `closePanel`. The
     * user's only escape is revoking the overlay permission. Tear it down
     * instead of trapping them.
     */
    private val panelWatchdog = Runnable {
        if (flutterView != null && engine?.renderer?.isDisplayingFlutterUi != true) {
            detachPanelWindow()
            Toast.makeText(
                this, "Exa panel could not open", Toast.LENGTH_SHORT,
            ).show()
        }
    }

    private val panelFirstFrame = object : FlutterUiDisplayListener {
        override fun onFlutterUiDisplayed() {
            mainHandler.removeCallbacks(panelWatchdog)
        }

        override fun onFlutterUiNoLongerDisplayed() = Unit
    }

    private val engineTeardown = Runnable {
        if (flutterView == null) {
            panelChannel?.setMethodCallHandler(null)
            panelChannel = null
            engine?.destroy()
            engine = null
        }
    }

    /**
     * Re-posts the notification when the screen goes dark, while lock-screen
     * access is on. Android 14 lets the user swipe a foreground-service
     * notification away; re-posting here means the Chat / Voice / Snippet
     * actions are back on the lock screen by the time they next look at it.
     */
    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF && isLockScreenEnabled()) {
                updateNotification()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        capture = ScreenCaptureController(this, ::onCaptureStateChanged)
        createNotificationChannel()
        val screenOff = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(screenOffReceiver, screenOff, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenOffReceiver, screenOff)
        }
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SHOW, null -> {
                // null = START_STICKY restart after the system killed us.
                if (intent != null || isEnabledInPrefs()) {
                    startAsForeground(withProjection = false)
                    prefs().edit().putBoolean(KEY_ENABLED, true).apply()
                    showBubble()
                    OverlayEvents.emit(OverlayEvents.BUBBLE_ENABLED)
                } else {
                    stopSelf()
                }
            }
            ACTION_HIDE -> {
                prefs().edit().putBoolean(KEY_ENABLED, false).apply()
                OverlayEvents.emit(OverlayEvents.BUBBLE_DISABLED)
                stopSelf()
            }
            ACTION_REQUEST_CONSENT -> launchConsent()
            ACTION_RESET_POSITION -> bubble?.resetPosition()
            ACTION_REFRESH_NOTIFICATION -> updateNotification()
            ACTION_OPEN_PANEL -> openPanelFromIntent(intent)
            ACTION_PROJECTION_RESULT -> adoptProjectionResult(intent)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        captureReady = false
        try {
            unregisterReceiver(screenOffReceiver)
        } catch (_: IllegalArgumentException) {
        }
        mainHandler.removeCallbacks(engineTeardown)
        mainHandler.removeCallbacks(openPanelAfterConsent)
        mainHandler.removeCallbacks(panelWatchdog)
        dismissFanMenu()
        removeBubble()
        detachPanelWindow(scheduleTeardown = false)
        panelChannel?.setMethodCallHandler(null)
        panelChannel = null
        engine?.destroy()
        engine = null
        capture.destroy()
        super.onDestroy()
    }

    // ---------------------------------------------------------------- bubble

    private fun showBubble() {
        if (bubble != null) return
        val view = BubbleView(this, windowManager, onTap = ::toggleFanMenu)
        windowManager.addView(view, view.windowParams)
        bubble = view
    }

    private fun removeBubble() {
        bubble?.let {
            try {
                windowManager.removeView(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        bubble = null
    }

    /**
     * Opens the requested panel as if the fan menu had been used - the
     * unlocked path for the notification's Chat / Voice / Snippet actions.
     * Makes sure the bubble is a running foreground service first, in case
     * the process was (re)started to deliver this.
     */
    private fun openPanelFromIntent(intent: Intent?) {
        if (bubble == null) {
            startAsForeground(withProjection = false)
            prefs().edit().putBoolean(KEY_ENABLED, true).apply()
            showBubble()
            OverlayEvents.emit(OverlayEvents.BUBBLE_ENABLED)
        }
        dismissFanMenu()
        val panel = intent?.getStringExtra(EXTRA_PANEL) ?: FanMenuView.ACTION_CHAT
        if (panel == FanMenuView.ACTION_SNIPPET) startSnippet() else openPanel(panel)
    }

    /**
     * Brings up the full app, optionally deep-linking [route] and asking it to
     * open a feature ([action], e.g. `voice` to start listening). Any open
     * overlay panel is torn down so the app is what the user lands on.
     */
    private fun openMainApp(route: String?, action: String? = null) {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK
                        or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
                .apply {
                    route?.let { putExtra("exa_route", it) }
                    action?.let { putExtra("exa_action", it) }
                },
        )
        detachPanelWindow()
    }

    private fun toggleFanMenu() {
        if (fanMenu != null) {
            dismissFanMenu()
            return
        }
        val anchor = bubble ?: return
        val menu = FanMenuView(
            this,
            onAction = { action ->
                dismissFanMenu()
                when (action) {
                    FanMenuView.ACTION_SNIPPET -> startSnippet()
                    // Voice opens the app and starts listening there: the
                    // overlay engine's speech recognizer does not reliably
                    // return a transcript, and the app's does.
                    FanMenuView.ACTION_VOICE ->
                        openMainApp(route = "/", action = FanMenuView.ACTION_VOICE)
                    else -> openPanel(action)
                }
            },
            onDismiss = ::dismissFanMenu,
        )
        windowManager.addView(menu, menu.windowParams)
        menu.present(anchor.centerX(), anchor.centerY())
        fanMenu = menu
    }

    private fun dismissFanMenu() {
        fanMenu?.let {
            try {
                windowManager.removeView(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        fanMenu = null
    }

    // --------------------------------------------------------------- snippet

    private fun startSnippet() {
        if (!capture.isReady) {
            pendingPanelAfterConsent = FanMenuView.ACTION_SNIPPET
            launchConsent()
            return
        }
        openPanel(FanMenuView.ACTION_SNIPPET)
    }

    /**
     * Hides our own windows so the snippet shows the app underneath, not the
     * Exa bubble or the selection overlay - but only once the capture is
     * listening, so that the hide is the very screen change the mirror needs
     * to emit a usable frame. See [ScreenCaptureController.captureFrame].
     */
    private fun captureFrameNow(result: MethodChannel.Result) {
        // Read the panel's geometry before hiding it: the frame covers the
        // whole display, the panel window may not (status bar, display cutout,
        // gesture insets), and Dart crops using the difference. Without it a
        // selection is off by that inset - the snippet bug.
        captureOneFrame(
            hostRect = panelRectOnScreen(),
            onSurfaceAttached = {},
            onDone = {},
        ) { frame, error ->
            if (frame != null) {
                result.success(frame)
            } else {
                result.error(
                    error ?: "capture_failed",
                    "Snippet failed - try again",
                    null,
                )
            }
        }
    }

    private fun captureOneFrame(
        hostRect: IntArray?,
        onSurfaceAttached: () -> Unit,
        onDone: () -> Unit,
        onResult: (Map<String, Any?>?, String?) -> Unit,
    ) {
        capture.captureFrame(
            // Our windows come down only once the mirror is listening, so the
            // change they make is itself the frame the capture waits for.
            onSurfaceAttached = {
                bubble?.visibility = View.INVISIBLE
                flutterView?.visibility = View.INVISIBLE
                onSurfaceAttached()
            },
        ) { png, width, height, error ->
            bubble?.visibility = View.VISIBLE
            flutterView?.visibility = View.VISIBLE
            onDone()
            // This stop is intentional: snippets use one frame only.
            expectedCaptureStop = true
            val (screenWidth, screenHeight) = capture.displaySize()
            capture.release()
            onCaptureStateChanged(false)
            expectedCaptureStop = false
            if (png != null) {
                onResult(
                    mapOf(
                        "png" to png,
                        "width" to width,
                        "height" to height,
                        "screenWidth" to screenWidth,
                        "screenHeight" to screenHeight,
                        "panelLeft" to (hostRect?.get(0) ?: 0),
                        "panelTop" to (hostRect?.get(1) ?: 0),
                        "panelWidth" to (hostRect?.get(2) ?: 0),
                        "panelHeight" to (hostRect?.get(3) ?: 0),
                    ),
                    null,
                )
            } else {
                onResult(null, error ?: "capture_failed")
            }
        }
    }

    private fun launchConsent() {
        // The consent dialog must be the only active Exa window. In
        // particular, never leave a fullscreen panel underneath it: on some
        // Android builds that window remains the top touch target after the
        // dialog is dismissed.
        dismissFanMenu()
        detachPanelWindow()
        try {
            startActivity(
                Intent(this, ProjectionConsentActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: Exception) {
            pendingPanelAfterConsent = null
            Toast.makeText(
                this, "Could not open screen capture permission",
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    private fun adoptProjectionResult(intent: Intent) {
        val resultCode =
            intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingPanelAfterConsent = null
            mainHandler.removeCallbacks(openPanelAfterConsent)
            Toast.makeText(
                this, "Screen capture permission declined", Toast.LENGTH_SHORT,
            ).show()
            return
        }
        // Android 14+: the service must be foreground WITH the mediaProjection
        // type before getMediaProjection is called.
        startAsForeground(withProjection = true)
        val manager =
            getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        try {
            val projection = manager.getMediaProjection(resultCode, data)
                ?: throw IllegalStateException("projection unavailable")
            capture.attach(projection)
        } catch (e: Exception) {
            pendingPanelAfterConsent = null
            mainHandler.removeCallbacks(openPanelAfterConsent)
            capture.release()
            onCaptureStateChanged(false)
            Toast.makeText(
                this, "Could not start screen capture: ${e.message}",
                Toast.LENGTH_SHORT,
            ).show()
            startAsForeground(withProjection = false)
        }
    }

    private fun onCaptureStateChanged(ready: Boolean) {
        // MediaProjection may report onStop after release() has already
        // notified us. Do not run the loss cleanup twice.
        if (!ready && !captureReady && !capture.isReady) return
        captureReady = ready
        updateNotification()
        if (ready) {
            OverlayEvents.emit(OverlayEvents.CAPTURE_READY)
            if (pendingPanelAfterConsent != null) {
                // Let ProjectionConsentActivity finish and its window leave
                // the display before adding our fullscreen selector.
                mainHandler.removeCallbacks(openPanelAfterConsent)
                mainHandler.postDelayed(openPanelAfterConsent, 300)
            }
        } else {
            OverlayEvents.emit(OverlayEvents.CAPTURE_LOST)
            pendingPanelAfterConsent = null
            // A projection can end from the status-bar chip, screen lock, or
            // a system failure. The fullscreen selector must not survive that
            // event because it would keep consuming touches over other apps.
            if (!expectedCaptureStop) detachPanelWindow()
            panelChannel?.invokeMethod("captureLost", null)
            // Drop back to the bubble-only foreground type.
            if (isRunning) startAsForeground(withProjection = false)
        }
    }

    // ------------------------------------------------- overlay Flutter panel

    private fun openPanel(panel: String) {
        launchPanel = panel
        mainHandler.removeCallbacks(engineTeardown)
        val coldStart = engine == null
        ensureEngine()
        val mode =
            if (panel == FanMenuView.ACTION_SNIPPET) MODE_SELECTOR else MODE_PANEL
        if (flutterView == null) {
            attachPanelWindow(mode)
        } else {
            applyWindowMode(mode)
        }
        // A freshly started engine pulls the panel via getLaunchPanel once
        // Dart boots; only a warm one is told to switch (telling a cold one
        // would double-deliver the snippet request and consume the pending
        // frame twice).
        if (!coldStart) {
            panelChannel?.invokeMethod(
                "panelRequested", mapOf("panel" to panel))
        }
    }

    private fun ensureEngine() {
        if (engine != null) return
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
        }
        val newEngine = FlutterEngine(applicationContext)
        // Handler registered before Dart runs so no early call is dropped.
        panelChannel = MethodChannel(
            newEngine.dartExecutor.binaryMessenger, PANEL_CHANNEL,
        ).apply { setMethodCallHandler(::handlePanelCall) }
        newEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "package:exa_mobile/overlay_main.dart",
                "overlayMain",
            ),
        )
        engine = newEngine
    }

    private fun attachPanelWindow(mode: String) {
        val activeEngine = engine ?: return
        val view = FlutterView(this, FlutterTextureView(this))
        view.attachToFlutterEngine(activeEngine)
        view.setBackgroundColor(Color.TRANSPARENT)
        activeEngine.lifecycleChannel.appIsResumed()
        panelParams = buildPanelParams(mode)
        windowManager.addView(view, panelParams)
        flutterView = view
        // Fires immediately when the engine is already rendering (warm panel),
        // so this only actually waits on a cold start.
        activeEngine.renderer.addIsDisplayingFlutterUiListener(panelFirstFrame)
        mainHandler.postDelayed(panelWatchdog, PANEL_FIRST_FRAME_TIMEOUT_MS)
    }

    private fun detachPanelWindow(scheduleTeardown: Boolean = true) {
        mainHandler.removeCallbacks(panelWatchdog)
        engine?.renderer?.removeIsDisplayingFlutterUiListener(panelFirstFrame)
        flutterView?.let { view ->
            try {
                windowManager.removeView(view)
            } catch (_: IllegalArgumentException) {
            }
            view.detachFromFlutterEngine()
        }
        flutterView = null
        panelParams = null
        engine?.lifecycleChannel?.appIsPaused()
        if (scheduleTeardown) {
            mainHandler.postDelayed(engineTeardown, ENGINE_IDLE_TEARDOWN_MS)
        }
    }

    /** Full window height, as opposed to the 62% bottom sheet. */
    private fun isFullHeight(mode: String) =
        mode == MODE_FULLSCREEN || mode == MODE_SELECTOR

    private fun panelHeightFor(mode: String) =
        if (isFullHeight(mode)) WindowManager.LayoutParams.MATCH_PARENT
        else (resources.displayMetrics.heightPixels * 0.62).toInt()

    private fun panelFlagsFor(mode: String): Int {
        var flags = (
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
            )
        // Only the region selector goes edge to edge. It is drawn over a frame
        // that covers the whole display, so anything the capture includes must
        // be selectable - and a window inset by the system bars would put the
        // dim overlay and the captured pixels out of step. The chat/compose
        // sheet keeps the insets so its controls stay clear of them.
        if (mode == MODE_SELECTOR) {
            flags = flags or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        }
        return flags
    }

    /** Lets the selector cover a notch instead of being letterboxed below it. */
    private fun applyCutoutMode(params: WindowManager.LayoutParams, mode: String) {
        if (Build.VERSION.SDK_INT < 28) return
        params.layoutInDisplayCutoutMode = when {
            mode != MODE_SELECTOR ->
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
            Build.VERSION.SDK_INT >= 30 ->
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            else ->
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    private fun buildPanelParams(mode: String): WindowManager.LayoutParams {
        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            panelHeightFor(mode),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            panelFlagsFor(mode),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = if (isFullHeight(mode)) Gravity.TOP else Gravity.BOTTOM
            softInputMode =
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
            applyCutoutMode(this, mode)
        }
    }

    private fun applyWindowMode(mode: String) {
        val view = flutterView ?: return
        val params = panelParams ?: return
        params.height = panelHeightFor(mode)
        params.gravity = if (isFullHeight(mode)) Gravity.TOP else Gravity.BOTTOM
        // Focusability is toggled independently (setPanelFocusable), so carry
        // whatever it is set to now across the mode change.
        val focusable =
            params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE == 0
        params.flags = panelFlagsFor(mode)
        if (focusable) {
            params.flags =
                params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        }
        applyCutoutMode(params, mode)
        windowManager.updateViewLayout(view, params)
    }

    /**
     * The panel window's rect on the display in pixels - `[left, top, width,
     * height]` - or null before it has been laid out. This is the panel's
     * position within a captured frame, which is what makes a snippet crop
     * land where the user drew it.
     */
    private fun panelRectOnScreen(): IntArray? {
        val view = flutterView ?: return null
        if (view.width <= 0 || view.height <= 0) return null
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        return intArrayOf(location[0], location[1], view.width, view.height)
    }

    private fun setPanelFocusable(focusable: Boolean) {
        val view = flutterView ?: return
        val params = panelParams ?: return
        params.flags = if (focusable) {
            params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        } else {
            params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        }
        windowManager.updateViewLayout(view, params)
    }

    private fun handlePanelCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getLaunchPanel" -> result.success(
                mapOf(
                    "panel" to launchPanel,
                    "captureState" to captureState(),
                    "host" to "overlay",
                ),
            )
            // Asked before every capture: a session is released after each
            // frame, so "do I need consent again?" is a live question rather
            // than something Dart can remember from last time.
            "captureState" -> result.success(captureState())
            "captureFrame" -> {
                if (!capture.isReady) {
                    result.error(
                        "capture_inactive",
                        "Screen capture permission is not active",
                        null,
                    )
                    return
                }
                captureFrameNow(result)
            }
            "setWindowMode" -> {
                applyWindowMode(call.argument<String>("mode") ?: MODE_PANEL)
                result.success(null)
            }
            "setFocusable" -> {
                setPanelFocusable(call.argument<Boolean>("focusable") ?: false)
                result.success(null)
            }
            "closePanel" -> {
                detachPanelWindow()
                result.success(null)
            }
            "requestCaptureConsent" -> {
                // `then` names the panel to reopen once consent lands, so the
                // user's one tap still ends in a capture instead of dumping
                // them back at the bubble to start over.
                pendingPanelAfterConsent = call.argument<String>("then")
                launchConsent()
                result.success(true)
            }
            "openMainApp" -> {
                openMainApp(route = call.argument<String>("route"))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------- notification

    private fun createNotificationChannel() {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Exa bubble",
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Keeps the floating Exa bubble running"
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                LOCK_CHANNEL_ID,
                "Exa on the lock screen",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Chat, Voice and Snippet buttons on the lock screen"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
    }

    private fun isLockScreenEnabled() = prefs().getBoolean(KEY_LOCK_SCREEN, false)

    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val hideIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ExaOverlayService::class.java).setAction(ACTION_HIDE),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val lockScreen = isLockScreenEnabled()
        val builder = Notification.Builder(
            this, if (lockScreen) LOCK_CHANNEL_ID else CHANNEL_ID,
        )
            .setContentTitle(
                if (lockScreen) "Exa - chat, speak or snip from here"
                else "Exa bubble is active",
            )
            .setContentText(
                if (captureReady) "Screen snippets ready"
                else "Snippets off - tap Snippet on the bubble to enable",
            )
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(contentIntent)
        if (lockScreen) {
            // Chat / Voice / Snippet open the real app on that feature - Voice
            // starts listening straight away. From the lock screen this means
            // the phone unlocks first (the app is not shown over the keyguard),
            // which is what "open Exa and start listening" asks for, and it
            // uses the app's own speech, which is reliable where the overlay
            // engine's is not. PUBLIC so the buttons show even when the user
            // hides sensitive notification content on the lock screen.
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)
            val actions = listOf(
                Triple(FanMenuView.ACTION_CHAT, "Chat", 10),
                Triple(FanMenuView.ACTION_VOICE, "Voice", 11),
                Triple(FanMenuView.ACTION_SNIPPET, "Snippet", 12),
            )
            for ((action, label, requestCode) in actions) {
                val open = Intent(this, MainActivity::class.java)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK
                            or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    )
                    .putExtra("exa_route", "/")
                    .putExtra("exa_action", action)
                val pending = PendingIntent.getActivity(
                    this,
                    requestCode,
                    open,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                builder.addAction(
                    Notification.Action.Builder(null, label, pending).build(),
                )
            }
        } else {
            builder.addAction(
                Notification.Action.Builder(null, "Hide bubble", hideIntent)
                    .build(),
            )
        }
        return builder.build()
    }

    private fun updateNotification() {
        if (!isRunning) return
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun startAsForeground(withProjection: Boolean) {
        val notification = buildNotification()
        when {
            Build.VERSION.SDK_INT >= 34 -> {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                if (withProjection) {
                    type = type or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                }
                startForeground(NOTIFICATION_ID, notification, type)
            }
            Build.VERSION.SDK_INT >= 29 -> startForeground(
                NOTIFICATION_ID,
                notification,
                if (withProjection) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                } else {
                    0
                },
            )
            else -> startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun isEnabledInPrefs() = prefs().getBoolean(KEY_ENABLED, false)
}

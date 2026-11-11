package com.brightforge.exa

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import com.brightforge.exa.messaging.MessagingChannel
import com.brightforge.exa.overlay.ExaOverlayService
import com.brightforge.exa.overlay.FanMenuView
import com.brightforge.exa.overlay.OverlayEvents
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val OVERLAY_CHANNEL = "com.brightforge.exa/overlay"
        private const val OVERLAY_EVENTS = "com.brightforge.exa/overlay_events"
    }

    /** Resolved on resume, after the user returns from the settings page. */
    private var pendingOverlayPermissionResult: MethodChannel.Result? = null

    /** Route pushed from the overlay panel's "open in app" action. */
    private var pendingLaunchRoute: String? = null

    /**
     * Feature to open on launch - `voice` / `chat` / `snippet` - from the
     * bubble's Voice action or a lock-screen notification button. Read by Dart
     * via `consumeLaunchAction` once the app is up.
     */
    private var pendingLaunchAction: String? = null

    /** Chat capture + the share/"process text" handoff. */
    private val messaging by lazy { MessagingChannel(this) }

    /**
     * Kept so a launch action arriving while the app is already in front can
     * be *pushed* to Dart. Polling on resume is not enough: pulling down the
     * notification shade over a running Exa does not always pause the
     * activity, so "resumed" may never fire and the Voice tap would do
     * nothing until the next time the app came back.
     */
    private var overlayChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLaunchRoute = intent?.getStringExtra("exa_route")
        pendingLaunchAction = intent?.getStringExtra("exa_action")

        // Registered before Dart can ask for it, and offered the launch
        // intent here rather than in onCreate: a share that cold-starts the
        // app has to survive until the assistant screen is listening.
        messaging.register(flutterEngine.dartExecutor.binaryMessenger)
        messaging.offerIntent(intent)

        overlayChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL,
        )
        overlayChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasOverlayPermission" ->
                    result.success(Settings.canDrawOverlays(this))
                "requestOverlayPermission" -> {
                    if (Settings.canDrawOverlays(this)) {
                        result.success(true)
                    } else {
                        pendingOverlayPermissionResult = result
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                    }
                }
                "isBubbleEnabled" -> result.success(ExaOverlayService.isRunning)
                "enableBubble" -> {
                    if (!Settings.canDrawOverlays(this)) {
                        result.success(false)
                    } else {
                        prefs().edit()
                            .putBoolean(ExaOverlayService.KEY_ENABLED, true)
                            .apply()
                        startForegroundService(
                            overlayIntent(ExaOverlayService.ACTION_SHOW),
                        )
                        result.success(true)
                    }
                }
                "disableBubble" -> {
                    prefs().edit()
                        .putBoolean(ExaOverlayService.KEY_ENABLED, false)
                        .apply()
                    if (ExaOverlayService.isRunning) {
                        startService(overlayIntent(ExaOverlayService.ACTION_HIDE))
                    }
                    result.success(true)
                }
                "captureState" -> result.success(ExaOverlayService.captureState())
                "requestCaptureConsent" -> {
                    if (ExaOverlayService.isRunning) {
                        startService(
                            overlayIntent(ExaOverlayService.ACTION_REQUEST_CONSENT),
                        )
                        result.success(true)
                    } else {
                        result.error(
                            "bubble_disabled",
                            "Enable the bubble before enabling snippets",
                            null,
                        )
                    }
                }
                "resetBubblePosition" -> {
                    prefs().edit()
                        .remove("bubble_x")
                        .remove("bubble_y")
                        .apply()
                    if (ExaOverlayService.isRunning) {
                        startService(
                            overlayIntent(ExaOverlayService.ACTION_RESET_POSITION),
                        )
                    }
                    result.success(null)
                }
                "consumeLaunchRoute" -> {
                    result.success(pendingLaunchRoute)
                    pendingLaunchRoute = null
                }
                "consumeLaunchAction" -> {
                    result.success(pendingLaunchAction)
                    pendingLaunchAction = null
                }
                "openOverlayPanel" -> {
                    val panel = call.argument<String>("panel")
                        ?: FanMenuView.ACTION_CHAT
                    if (ExaOverlayService.isRunning) {
                        startService(
                            overlayIntent(ExaOverlayService.ACTION_OPEN_PANEL)
                                .putExtra(ExaOverlayService.EXTRA_PANEL, panel),
                        )
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "isLockScreenEnabled" -> result.success(
                    prefs().getBoolean(ExaOverlayService.KEY_LOCK_SCREEN, false),
                )
                "setLockScreenEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    prefs().edit()
                        .putBoolean(ExaOverlayService.KEY_LOCK_SCREEN, enabled)
                        .apply()
                    // The bubble notification is what carries the lock-screen
                    // actions; have the running service rebuild it now.
                    if (ExaOverlayService.isRunning) {
                        startService(
                            overlayIntent(ExaOverlayService.ACTION_REFRESH_NOTIFICATION),
                        )
                    }
                    result.success(enabled)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, OVERLAY_EVENTS,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                OverlayEvents.setListener { events.success(it) }
            }

            override fun onCancel(arguments: Any?) {
                OverlayEvents.setListener(null)
            }
        })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("exa_route")?.let { pendingLaunchRoute = it }
        // A notification action on an already-running app arrives here. Push
        // it rather than waiting to be polled: the shade can be pulled over a
        // resumed activity without pausing it, so "on resume" may never come.
        intent.getStringExtra("exa_action")?.let {
            pendingLaunchAction = it
            overlayChannel?.invokeMethod("launchActionPushed", null)
        }
        // singleTop: sharing into an already-open Exa arrives here, not in
        // configureFlutterEngine.
        messaging.offerIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        pendingOverlayPermissionResult?.let {
            it.success(Settings.canDrawOverlays(this))
            pendingOverlayPermissionResult = null
        }
    }

    private fun overlayIntent(action: String): Intent =
        Intent(this, ExaOverlayService::class.java).setAction(action)

    private fun prefs() =
        getSharedPreferences(ExaOverlayService.PREFS, Context.MODE_PRIVATE)
}

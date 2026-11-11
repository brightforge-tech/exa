package com.brightforge.exa.jobs

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import com.brightforge.exa.MainActivity
import com.brightforge.exa.R
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs the user's scheduled jobs for as long as they take.
 *
 * Scheduled jobs used to run inside a WorkManager worker, and Android stops
 * a worker after about ten minutes. A job that calls a slow model on the
 * user's own hardware needs longer than that on an ordinary day: a morning
 * summary measured six and a half minutes of model time, and the chat digest
 * timed out twice and was interrupted four times in one evening. A
 * foreground service has no such limit - it is what Android provides for
 * work the user asked for that has to finish.
 *
 * The service hosts a FlutterEngine running `jobServiceMain`, which runs
 * whatever is due and reports back on [CHANNEL]. It is started from the
 * exact-alarm callback through the device plugin, because that callback
 * runs in a background isolate where only plugins are reachable. If the
 * start is refused the alarm falls back to the WorkManager path, so the
 * worst case is the behaviour there was before.
 *
 * Three things bound it, since nothing else will: a partial wakelock with a
 * timeout, a watchdog that stops the service if Dart never reports back,
 * and the time budget Dart itself runs the jobs under.
 */
class ExaJobService : Service() {

    companion object {
        const val CHANNEL = "com.brightforge.exa/job_service"
        private const val TAG = "ExaJobService"
        /**
         * Its own channel, and the name matters. This was first written as
         * "exa_jobs", which is the id the app's job results already used:
         * creating a channel that exists updates it, and an update may lower
         * its importance. Every job result notification went silent.
         */
        private const val NOTIFICATION_CHANNEL_ID = "exa_job_running"
        private const val NOTIFICATION_ID = 7302

        /** Longer than the budget Dart runs under, so Dart normally ends it. */
        private const val MAX_RUN_MS = 25L * 60 * 1000

        private const val DART_LIBRARY = "package:exa_mobile/job_service_main.dart"
        private const val DART_ENTRYPOINT = "jobServiceMain"
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val watchdog = Runnable { finish("no word from the run in ${MAX_RUN_MS / 60000} min") }
    private var statusLine = "Running scheduled jobs"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // First, always: a service started with startForegroundService has a
        // few seconds to call this before the system kills the process.
        try {
            startAsForeground()
        } catch (e: Exception) {
            Log.w(TAG, "could not enter the foreground: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        if (engine != null) {
            // A run is in flight. It looks for newly due jobs before it
            // finishes, so this alarm is not lost.
            channel?.invokeMethod("wake", null)
            return START_NOT_STICKY
        }
        acquireWakeLock()
        mainHandler.postDelayed(watchdog, MAX_RUN_MS)
        try {
            startEngine()
        } catch (e: Throwable) {
            Log.w(TAG, "could not start the job engine: ${e.message}")
            finish("engine failed to start")
        }
        // Not sticky: a run the system killed is picked up by the next alarm
        // or the WorkManager tick, through the ledger, not by a restart with
        // nothing to tell it what it was doing.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun startEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
        }
        val newEngine = FlutterEngine(applicationContext)
        // Registered before Dart runs so an early call is not dropped.
        channel = MethodChannel(newEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> {
                        statusLine = call.argument<String>("text") ?: statusLine
                        updateNotification()
                        result.success(null)
                    }
                    "done" -> {
                        result.success(null)
                        finish("run finished")
                    }
                    else -> result.notImplemented()
                }
            }
        }
        newEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                DART_LIBRARY,
                DART_ENTRYPOINT,
            ),
        )
        engine = newEngine
    }

    private fun finish(reason: String) {
        Log.i(TAG, "stopping: $reason")
        teardown()
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun teardown() {
        mainHandler.removeCallbacks(watchdog)
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun acquireWakeLock() {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "exa:scheduled-jobs").apply {
            setReferenceCounted(false)
            acquire(MAX_RUN_MS)
        }
    }

    // ---------------------------------------------------------- notification

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Scheduled job running",
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Shown while a scheduled job is running"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Exa is working")
            .setContentText(statusLine)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }

    private fun updateNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}

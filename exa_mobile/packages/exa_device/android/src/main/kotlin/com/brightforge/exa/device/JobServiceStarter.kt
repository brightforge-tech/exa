package com.brightforge.exa.device

import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Starts the app's scheduled-job foreground service.
 *
 * Lives in the plugin because the caller is the exact-alarm callback, which
 * runs in a background isolate: a channel on the activity does not exist
 * there, a plugin's does. The service itself lives in the app, which this
 * package cannot depend on, so it is named rather than referenced.
 *
 * Android may refuse (an app in the background needs an exemption to start
 * a foreground service; Exa holds several, none of them guaranteed). That
 * is reported, not thrown: the caller falls back to the worker it used
 * before.
 */
object JobServiceStarter {
    private const val SERVICE_CLASS = "com.brightforge.exa.jobs.ExaJobService"

    fun start(context: Context): Map<String, Any?> = try {
        val intent = Intent().setClassName(context.packageName, SERVICE_CLASS)
        val started = if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
        if (started == null) {
            mapOf("ok" to false, "error" to "The job service is not part of this build")
        } else {
            mapOf("ok" to true)
        }
    } catch (e: Exception) {
        mapOf("ok" to false, "error" to (e.message ?: e::class.java.simpleName))
    }
}

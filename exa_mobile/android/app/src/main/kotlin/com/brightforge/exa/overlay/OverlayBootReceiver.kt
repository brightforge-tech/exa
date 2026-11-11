package com.brightforge.exa.overlay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings

/**
 * Restores the bubble after a reboot or app update when the user had it
 * enabled. Starts the service with the specialUse role only: Android 15
 * forbids launching a mediaProjection foreground service from
 * BOOT_COMPLETED, and capture consent is per-session anyway - the first
 * Snippet tap re-runs consent.
 */
class OverlayBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val prefs = context.getSharedPreferences(
            ExaOverlayService.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(ExaOverlayService.KEY_ENABLED, false)) return
        if (!Settings.canDrawOverlays(context)) return
        context.startForegroundService(
            Intent(context, ExaOverlayService::class.java)
                .setAction(ExaOverlayService.ACTION_SHOW),
        )
    }
}

package com.brightforge.exa.device

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * The component `dpm set-device-owner com.brightforge.exa/com.brightforge.exa.device.ExaDeviceAdminReceiver`
 * names. It has no behaviour of its own: Device Owner powers are used through
 * [AdminActions], and the receiver exists so the system has an admin
 * component to bind the ownership to.
 */
class ExaDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        Log.i(TAG, "Exa device admin enabled")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        Log.i(TAG, "Exa device admin disabled")
    }

    override fun onDisableRequested(context: Context, intent: Intent): CharSequence =
        "Exa will lose device control: app management, settings, screen " +
            "reading and the other device tools stop working until it is set " +
            "up again with adb."

    companion object {
        private const val TAG = "ExaDevice"
    }
}

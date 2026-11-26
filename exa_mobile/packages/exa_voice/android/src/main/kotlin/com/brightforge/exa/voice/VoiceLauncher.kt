package com.brightforge.exa.voice

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * Opens Exa's voice session and posts the notifications that lead to it.
 *
 * The session is `VoiceActivity` in the app module. This module cannot
 * depend on the app, so the activity is addressed by class name; the class
 * keeps its `com.brightforge.exa` name whatever the installed package is.
 */
object VoiceLauncher {
    private const val TAG = "ExaVoice"
    const val VOICE_ACTIVITY = "com.brightforge.exa.voice.VoiceActivity"

    /** Extras the session reads on launch (see `consumeLaunch`). */
    const val EXTRA_MODE = "exa_voice_mode"
    const val EXTRA_PROMPT = "exa_voice_prompt"
    const val EXTRA_SPEAK = "exa_voice_speak"
    const val EXTRA_FOLLOW_UP_ID = "exa_voice_follow_up"

    /** Listen first: the side button, "Hey Exa", the in-app shortcut. */
    const val MODE_LISTEN = "listen"

    /** Exa speaks first, from [EXTRA_PROMPT]: an announcement or a question. */
    const val MODE_FOLLOW_UP = "follow_up"

    const val CHANNEL_FOLLOW_UPS = "exa_follow_ups"
    private const val CHANNEL_FOLLOW_UPS_NAME = "Exa follow-ups"

    fun sessionIntent(
        context: Context,
        mode: String,
        prompt: String? = null,
        speak: String? = null,
        followUpId: String? = null,
    ): Intent = Intent()
        .setClassName(context.packageName, VOICE_ACTIVITY)
        .addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        .putExtra(EXTRA_MODE, mode)
        .apply {
            if (prompt != null) putExtra(EXTRA_PROMPT, prompt)
            if (speak != null) putExtra(EXTRA_SPEAK, speak)
            if (followUpId != null) putExtra(EXTRA_FOLLOW_UP_ID, followUpId)
        }

    /**
     * Starts the session now. Allowed from the background only because Exa
     * holds "display over other apps" (the bubble needs it); without that,
     * Android drops the start silently, so the caller is told and falls back
     * to a notification.
     */
    fun open(
        context: Context,
        mode: String,
        prompt: String? = null,
        speak: String? = null,
        followUpId: String? = null,
    ): Boolean {
        wakeScreen(context)
        return try {
            context.startActivity(sessionIntent(context, mode, prompt, speak, followUpId))
            true
        } catch (e: Exception) {
            Log.w(TAG, "Could not open the voice session", e)
            false
        }
    }

    /**
     * Lights the screen before the session starts. The activity asks to turn
     * the screen on as well, but an activity started while the display is
     * dozing is not always brought forward until something wakes it - and a
     * session nobody can see looks like Exa ignoring them.
     */
    @Suppress("DEPRECATION")
    private fun wakeScreen(context: Context) {
        try {
            val power = context.getSystemService(PowerManager::class.java) ?: return
            if (power.isInteractive) return
            power.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "exa:voice-session",
            ).acquire(10_000)
        } catch (e: Exception) {
            Log.w(TAG, "Could not wake the screen", e)
        }
    }

    fun canStartFromBackground(context: Context): Boolean =
        Settings.canDrawOverlays(context)

    fun canUseFullScreen(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val manager = context.getSystemService(NotificationManager::class.java)
        return manager?.canUseFullScreenIntent() ?: false
    }

    fun isLocked(context: Context): Boolean =
        context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked ?: false

    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_FOLLOW_UPS) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_FOLLOW_UPS,
                CHANNEL_FOLLOW_UPS_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "What Exa added for you, and questions it has " +
                    "about things it could not add on its own."
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    /**
     * A follow-up notification: what Exa added or wants to ask, with "Talk
     * about it" opening the voice session on [prompt].
     *
     * [ring] also opens the session straight away, so Exa says it out loud -
     * over the lock screen too. That goes through "display over other apps",
     * which Exa holds for its bubble: Android 14 refuses full-screen
     * notifications to sideloaded apps by default, and relying on one left
     * "say it out loud" silently doing nothing. A full-screen notification is
     * the fallback only when the direct start is not allowed.
     *
     * Returns how it was delivered: spoken, full_screen or notified.
     */
    fun postFollowUp(
        context: Context,
        id: Int,
        title: String,
        body: String,
        prompt: String,
        speak: String?,
        followUpId: String?,
        ring: Boolean,
    ): String {
        ensureChannel(context)
        val talk = PendingIntent.getActivity(
            context,
            id,
            sessionIntent(context, MODE_FOLLOW_UP, prompt, speak, followUpId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val openApp = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val open = openApp?.let {
            PendingIntent.getActivity(
                context,
                id + 1,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val builder = Notification.Builder(context, CHANNEL_FOLLOW_UPS)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setContentIntent(open ?: talk)
            .addAction(Notification.Action.Builder(null, "Talk about it", talk).build())
        val direct = ring && canStartFromBackground(context)
        if (ring && !direct && canUseFullScreen(context)) {
            builder.setFullScreenIntent(talk, true)
        }
        if (direct) {
            // The session is about to say it; the notification stays as the
            // record, without a second sound on top of Exa's voice.
            builder.setOnlyAlertOnce(true)
        }
        context.getSystemService(NotificationManager::class.java)?.notify(id, builder.build())
        if (direct && open(context, MODE_FOLLOW_UP, prompt, speak, followUpId)) {
            return "spoken"
        }
        return if (ring && canUseFullScreen(context)) "full_screen" else "notified"
    }

    fun cancel(context: Context, id: Int) {
        context.getSystemService(NotificationManager::class.java)?.cancel(id)
    }
}

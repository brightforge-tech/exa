package com.brightforge.exa.voice

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * Exa's voice session: the side button / "Hey Exa" / a spoken follow-up.
 *
 * Shown over the lock screen and allowed to wake the screen, like an alarm,
 * because that is where a voice assistant is used. It runs its own Dart
 * entrypoint (`voiceMain`) so the only UI reachable without unlocking is the
 * conversation itself - none of the app's screens, history or settings -
 * and every turn it runs while the phone is locked is held to the lock-screen
 * capability policy (reads and local changes; nothing sent or deleted).
 */
class VoiceActivity : FlutterActivity() {

    override fun getDartEntrypointFunctionName(): String = "voiceMain"

    // Resolved in main.dart: the engine group FlutterActivity starts its
    // engine through ignores any other library (see main.dart's voiceMain).

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // The speech recogniser needs the microphone the wake word holds.
        WakeWordService.send(this, WakeWordService.ACTION_PAUSE)
    }

    override fun onDestroy() {
        WakeWordService.send(this, WakeWordService.ACTION_RESUME)
        super.onDestroy()
    }
}

package com.brightforge.exa.overlay

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle

/**
 * Invisible trampoline that shows the system screen-capture consent dialog
 * and forwards the grant to [ExaOverlayService]. Needed because consent can
 * only be requested from an Activity, but the projection lives in the
 * service.
 */
class ProjectionConsentActivity : Activity() {

    companion object {
        private const val REQUEST_CODE = 4301
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val manager =
            getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        @Suppress("DEPRECATION")
        startActivityForResult(consentIntent(manager), REQUEST_CODE)
    }

    /**
     * Asks for the whole display up front.
     *
     * Android 14 added the "entire screen / a single app" chooser the user
     * sees on this dialog; declaring the display here removes that choice, so
     * the dialog opens already committed to the full screen and is one tap.
     * A snippet crops out of a full-screen frame, so the single-app option was
     * never the right answer anyway.
     *
     * The confirmation tap itself cannot be skipped: the grant is issued by
     * the system dialog, and there is no API for an app to pre-approve its own
     * screen capture. Fewer prompts has to come from re-using a granted
     * session, not from answering this one automatically.
     */
    private fun consentIntent(manager: MediaProjectionManager): Intent =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            manager.createScreenCaptureIntent(
                MediaProjectionConfig.createConfigForDefaultDisplay(),
            )
        } else {
            // Pre-14 dialogs have no chooser - they are already full-screen.
            manager.createScreenCaptureIntent()
        }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE) {
            startService(
                Intent(this, ExaOverlayService::class.java).apply {
                    action = ExaOverlayService.ACTION_PROJECTION_RESULT
                    putExtra(ExaOverlayService.EXTRA_RESULT_CODE, resultCode)
                    putExtra(ExaOverlayService.EXTRA_RESULT_DATA, data)
                },
            )
        }
        finish()
    }
}

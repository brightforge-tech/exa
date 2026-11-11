package com.brightforge.exa

import android.app.Application
import android.content.Context
import androidx.work.Configuration
import com.brightforge.exa.messaging.ReplyRegistry
import com.brightforge.exa.phone.ExaPhonePlugin
import com.brightforge.exa.widget.BriefingDbWatcher
import com.brightforge.exa.widget.BriefingWidget

/**
 * Supplies WorkManager's configuration so it can initialize on demand.
 *
 * WorkManager normally initializes itself from the androidx.startup
 * `InitializationProvider` declared in the merged manifest. In this app's R8
 * release build that automatic path does not run, and the failure is fatal
 * rather than degraded: workmanager_android builds its `WorkManagerWrapper`
 * in `onAttachedToEngine`, and the wrapper calls `WorkManager.getInstance()`
 * in a property initializer, so the resulting IllegalStateException is thrown
 * on a Dispatchers.Default coroutine thread during plugin registration. That
 * is an uncaught Kotlin exception, not a channel error, so the try/catch
 * around registerBackgroundJobs() in main.dart never sees it - the process
 * died about 450ms into launch, before Flutter drew a frame.
 *
 * Implementing Configuration.Provider is WorkManager's documented on-demand
 * initialization path: getInstance() finds the Application here and
 * initializes from this configuration instead of throwing. It also makes
 * startup independent of whether the androidx.startup provider ran at all,
 * which is what made the automatic path fragile here in the first place.
 */
class ExaApplication :
    Application(),
    Configuration.Provider {
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().build()

    override fun onCreate() {
        super.onCreate()
        // Lend the phone plugin the chat reply handles. send_whatsapp answers
        // a chat through WhatsApp's own notification reply action when one is
        // live (the only way to send without the user tapping), and those
        // handles live in ReplyRegistry here in the app module. The plugin
        // cannot depend on the app, so the app hands it the bridge - once per
        // process, which covers every engine the plugin is registered in.
        ExaPhonePlugin.replyDelegate = object : ExaPhonePlugin.ReplyDelegate {
            override fun canReply(channel: String, conversationId: String) =
                ReplyRegistry.canReply(channel, conversationId)

            override fun send(
                context: Context,
                channel: String,
                conversationId: String,
                text: String,
            ): String? = ReplyRegistry.send(context, channel, conversationId, text)
        }
        // Whatever woke the process may be about to write to the database;
        // with a briefing widget on the home screen, have it follow along.
        if (BriefingWidget.hasWidgets(this)) BriefingDbWatcher.start(this)
    }
}

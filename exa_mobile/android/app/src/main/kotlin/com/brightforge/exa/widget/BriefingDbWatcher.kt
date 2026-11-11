package com.brightforge.exa.widget

import android.content.Context
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import java.io.File

/**
 * Redraws the briefing widget when the app database changes.
 *
 * Watching the files rather than hooking Dart's repositories catches every
 * writer - the chat, scheduled jobs in the WorkManager and alarm isolates,
 * calendar sync - with no change on the Dart side, because every one of them
 * writes from this process and so while this watcher is alive. When the
 * process is gone nothing is writing, and the widget's own alarm covers the
 * passage of time.
 *
 * Only `exa.db` and its WAL count: readers (including the widget's own
 * read-only connection) touch the `-shm` index, and reacting to that would
 * make every redraw trigger the next one.
 *
 * Redraws are throttled, not debounced: a long agent run writes steadily for
 * minutes, and a trailing debounce would hold the widget stale until it ends.
 */
object BriefingDbWatcher {
    private const val THROTTLE_MS = 3_000L
    private val watched = setOf("exa.db", "exa.db-wal")

    private val main = Handler(Looper.getMainLooper())
    private var observer: FileObserver? = null
    private var appContext: Context? = null
    private var pending = false

    private val fire = Runnable {
        synchronized(this) { pending = false }
        appContext?.let { BriefingWidget.update(it) }
    }

    @Synchronized
    fun start(context: Context) {
        if (observer != null) return
        val dir = context.getDatabasePath("exa.db").parentFile ?: return
        // sqflite creates the folder on first launch; until then there is
        // nothing to watch and the next process start will try again.
        if (!dir.isDirectory) return
        appContext = context.applicationContext
        val mask = FileObserver.MODIFY or FileObserver.CLOSE_WRITE or
            FileObserver.MOVED_TO or FileObserver.DELETE
        observer = newObserver(dir, mask).also { it.startWatching() }
    }

    @Synchronized
    fun stop() {
        observer?.stopWatching()
        observer = null
        main.removeCallbacks(fire)
        pending = false
    }

    private fun onChange(name: String?) {
        if (name !in watched) return
        synchronized(this) {
            if (pending) return
            pending = true
        }
        main.postDelayed(fire, THROTTLE_MS)
    }

    private fun newObserver(dir: File, mask: Int): FileObserver =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            object : FileObserver(dir, mask) {
                override fun onEvent(event: Int, path: String?) = onChange(path)
            }
        } else {
            @Suppress("DEPRECATION")
            object : FileObserver(dir.path, mask) {
                override fun onEvent(event: Int, path: String?) = onChange(path)
            }
        }
}

package com.brightforge.exa.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * The Exa briefing home-screen widget: today's events, tasks and reminders
 * ("nudges"), and the next thing on the calendar.
 *
 * Every entry point hands off to [BriefingWidget.update], which reads the
 * database on a worker thread; `goAsync()` keeps the receiver (and so the
 * process) alive until that redraw has landed.
 */
class BriefingWidgetProvider : AppWidgetProvider() {

    companion object {
        /** A tab chip was tapped; carries [EXTRA_TAB] and the widget id. */
        const val ACTION_TAB = "com.brightforge.exa.widget.TAB"

        /** The self-scheduled redraw alarm (see BriefingWidget.scheduleRefresh). */
        const val ACTION_REFRESH = "com.brightforge.exa.widget.REFRESH"

        const val EXTRA_TAB = "tab"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_TAB -> {
                val id = intent.getIntExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    AppWidgetManager.INVALID_APPWIDGET_ID,
                )
                if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
                BriefingWidget.selectTab(
                    context, id, intent.getIntExtra(EXTRA_TAB, BriefingWidget.TAB_ALL),
                )
                redraw(context, intArrayOf(id))
            }
            ACTION_REFRESH,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> redraw(context, null)
            else -> super.onReceive(context, intent)
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) = redraw(context, appWidgetIds)

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) = redraw(context, intArrayOf(appWidgetId))

    override fun onDeleted(context: Context, appWidgetIds: IntArray) =
        BriefingWidget.forget(context, appWidgetIds)

    // The last widget removed: the redraw finds none placed and cancels its
    // alarm and the database watcher.
    override fun onDisabled(context: Context) = redraw(context, null)

    private fun redraw(context: Context, ids: IntArray?) {
        val pending = goAsync()
        BriefingWidget.update(context, ids) { pending.finish() }
    }
}

package com.brightforge.exa.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.format.DateFormat
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import com.brightforge.exa.MainActivity
import com.brightforge.exa.R
import java.time.Duration
import java.time.LocalDate
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Draws the Exa briefing widget and decides when it next needs drawing.
 *
 * All work runs on one background thread: the database read is small but it
 * is still disk I/O, and serialising redraws means a burst of database writes
 * can never interleave two half-built updates.
 */
object BriefingWidget {
    private const val TAG = "ExaBriefingWidget"
    private const val PREFS = "exa_briefing_widget"

    const val TAB_ALL = 0
    const val TAB_EVENTS = 1
    const val TAB_TASKS = 2
    const val TAB_NUDGES = 3

    private val worker = Executors.newSingleThreadExecutor()

    // Palette, matching the drawables in res/drawable/widget_*.
    private const val TEXT = 0xFFF2EFE9.toInt()
    private const val TEXT_MUTED = 0xFF8E9AA0.toInt()
    private const val TEXT_SOFT = 0xFFAEB7BC.toInt()
    private const val ACCENT = 0xFF5CC9D3.toInt()
    private const val GREEN = 0xFF3DDC97.toInt()
    private const val AMBER = 0xFFF5A524.toInt()
    private const val RED = 0xFFFF8A8A.toInt()

    private val joinLink = Regex(
        "https?://(meet\\.google\\.com|[\\w.-]*zoom\\.us|teams\\.microsoft\\.com|" +
            "teams\\.live\\.com|[\\w.-]*webex\\.com)/\\S+",
        RegexOption.IGNORE_CASE,
    )
    private val anyLink = Regex("https?://\\S+", RegexOption.IGNORE_CASE)

    fun component(context: Context) =
        ComponentName(context, BriefingWidgetProvider::class.java)

    fun hasWidgets(context: Context): Boolean =
        AppWidgetManager.getInstance(context).getAppWidgetIds(component(context))
            .isNotEmpty()

    /**
     * Redraws [ids] (every placed widget when null) off the main thread, then
     * calls [done]. Callers in a receiver pass `goAsync().finish` so the
     * process is kept alive until the redraw has landed.
     */
    fun update(context: Context, ids: IntArray? = null, done: () -> Unit = {}) {
        val app = context.applicationContext
        worker.execute {
            try {
                redraw(app, ids)
            } catch (e: Exception) {
                Log.w(TAG, "Widget redraw failed", e)
            } finally {
                done()
            }
        }
    }

    /**
     * Also asks the next redraw to put the list back at the top: a ListView
     * keeps its scroll offset when its items are swapped, so the new tab would
     * otherwise open part-way down.
     */
    fun selectTab(context: Context, widgetId: Int, tab: Int) {
        prefs(context).edit()
            .putInt("tab_$widgetId", tab)
            .putBoolean("scroll_top_$widgetId", true)
            .apply()
    }

    fun forget(context: Context, widgetIds: IntArray) {
        val edit = prefs(context).edit()
        widgetIds.forEach { edit.remove("tab_$it").remove("scroll_top_$it") }
        edit.apply()
    }

    private fun redraw(context: Context, onlyIds: IntArray?) {
        val manager = AppWidgetManager.getInstance(context)
        val placed = manager.getAppWidgetIds(component(context))
        if (placed.isEmpty()) {
            cancelRefresh(context)
            BriefingDbWatcher.stop()
            return
        }
        BriefingDbWatcher.start(context)
        val snapshot = BriefingReader.read(context, ZonedDateTime.now())
        if (snapshot != null) {
            for (id in onlyIds ?: placed) {
                manager.updateAppWidget(id, build(context, manager, id, snapshot))
            }
        }
        scheduleRefresh(context, snapshot)
    }

    // ---------------------------------------------------------------- views

    private fun build(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        s: BriefingSnapshot,
    ): RemoteViews {
        val v = RemoteViews(context.packageName, R.layout.widget_briefing)
        val time = timeFormatter(context)
        val tab = prefs(context).getInt("tab_$widgetId", TAB_ALL)

        // Header.
        v.setTextViewText(
            R.id.date_label,
            s.now.format(DateTimeFormatter.ofPattern("EEEE, MMM d", Locale.getDefault()))
                .uppercase(Locale.getDefault()),
        )
        v.setTextViewText(R.id.sync_label, "Exa synced ${s.now.format(time)}")
        val hello = greetingFor(s.now)
        v.setTextViewText(
            R.id.greeting,
            if (s.ownerFirstName != null) "$hello, ${s.ownerFirstName}" else hello,
        )
        v.setTextViewText(R.id.subtitle, subtitle(s))

        // Briefing card.
        v.setTextViewText(R.id.briefing_text, briefingText(s))
        when {
            s.overlaps > 0 -> pill(v, R.id.briefing_pill, plural(s.overlaps, "overlap"), "amber")
            s.overdueCount > 0 -> pill(v, R.id.briefing_pill, "${s.overdueCount} overdue", "red")
            else -> pill(v, R.id.briefing_pill, "On track", "green")
        }
        v.setTextViewText(R.id.briefing_meta, "${plural(s.openTaskCount, "open task")} in all")

        // Tiles.
        val eventsToday = s.todayEvents.size
        v.setTextViewText(R.id.tile_events_value, "$eventsToday Today")
        val (eventSub, eventColor) = eventTileLine(s, time)
        v.setTextViewText(R.id.tile_events_sub, eventSub)
        v.setTextColor(R.id.tile_events_sub, eventColor)
        dot(v, R.id.tile_events_dot, if (s.eventsLeftToday.isEmpty()) "muted" else "lavender")

        v.setTextViewText(R.id.tile_tasks_value, "${s.focusTasks.size} Focus")
        when {
            s.overdueCount > 0 -> {
                v.setTextViewText(R.id.tile_tasks_sub, "${s.overdueCount} overdue")
                v.setTextColor(R.id.tile_tasks_sub, RED)
            }
            s.dueTodayCount > 0 -> {
                v.setTextViewText(R.id.tile_tasks_sub, "${s.dueTodayCount} due today")
                v.setTextColor(R.id.tile_tasks_sub, GREEN)
            }
            else -> {
                v.setTextViewText(R.id.tile_tasks_sub, "${s.openTaskCount} open")
                v.setTextColor(R.id.tile_tasks_sub, TEXT_SOFT)
            }
        }
        dot(
            v, R.id.tile_tasks_dot,
            when {
                s.overdueCount > 0 -> "red"
                s.focusTasks.isNotEmpty() -> "green"
                else -> "muted"
            },
        )

        val remindersToday = s.remindersToday.size
        v.setTextViewText(R.id.tile_nudges_value, "$remindersToday Active")
        val nextReminder = s.upcomingReminders.firstOrNull()
        if (nextReminder != null) {
            val date = nextReminder.at.toLocalDate()
            val today = s.now.toLocalDate()
            val day = when (date) {
                today -> ""
                today.plusDays(1) -> "Tmrw "
                else -> date.format(DateTimeFormatter.ofPattern("EEE ", Locale.getDefault()))
            }
            v.setTextViewText(
                R.id.tile_nudges_sub,
                "$day${nextReminder.at.format(time)} ${nextReminder.title}",
            )
            v.setTextColor(R.id.tile_nudges_sub, AMBER)
        } else {
            v.setTextViewText(R.id.tile_nudges_sub, "None coming up")
            v.setTextColor(R.id.tile_nudges_sub, TEXT_SOFT)
        }
        dot(v, R.id.tile_nudges_dot, if (remindersToday > 0) "amber" else "muted")

        // Tabs.
        tabLabel(v, R.id.tab_all, "All Glance", tab == TAB_ALL)
        tabLabel(v, R.id.tab_events, "Events ($eventsToday)", tab == TAB_EVENTS)
        tabLabel(v, R.id.tab_tasks, "Tasks (${s.focusTasks.size})", tab == TAB_TASKS)
        tabLabel(v, R.id.tab_nudges, "Nudges ($remindersToday)", tab == TAB_NUDGES)

        // Content for the chosen tab, sized to the space the launcher gave.
        val height = heightDp(manager, widgetId)
        val roomy = height == 0 || height >= 450
        v.setViewVisibility(R.id.briefing_card, if (height == 0 || height >= 330) View.VISIBLE else View.GONE)
        v.setViewVisibility(R.id.tabs, if (roomy) View.VISIBLE else View.GONE)
        v.setViewVisibility(R.id.content, if (roomy) View.VISIBLE else View.GONE)
        val listSpace = if (height == 0) 3 * ROW_DP else height - ABOVE_LIST_DP

        if (tab == TAB_ALL) {
            v.setViewVisibility(R.id.next_up, View.VISIBLE)
            v.setViewVisibility(R.id.list_panel, View.GONE)
            nextUp(context, v, widgetId, s, time)
        } else {
            v.setViewVisibility(R.id.next_up, View.GONE)
            v.setViewVisibility(R.id.list_panel, View.VISIBLE)
            // Only after a tab change: routine redraws must not move a list
            // the user is scrolling.
            val scrollTop = prefs(context).getBoolean("scroll_top_$widgetId", false)
            if (scrollTop) prefs(context).edit().remove("scroll_top_$widgetId").apply()
            list(context, v, widgetId, tab, s, time, listSpace, scrollTop)
        }

        // Taps.
        v.setOnClickPendingIntent(android.R.id.background, openApp(context, widgetId, 0, "/"))
        v.setOnClickPendingIntent(R.id.briefing_card, openApp(context, widgetId, 1, "/", "chat"))
        v.setOnClickPendingIntent(R.id.briefing_voice, openApp(context, widgetId, 2, "/", "voice"))
        v.setOnClickPendingIntent(R.id.tile_events, openApp(context, widgetId, 3, "/schedule"))
        v.setOnClickPendingIntent(R.id.tile_tasks, openApp(context, widgetId, 4, "/tasks"))
        v.setOnClickPendingIntent(R.id.tile_nudges, openApp(context, widgetId, 5, "/reminders"))
        v.setOnClickPendingIntent(R.id.tab_all, tabIntent(context, widgetId, TAB_ALL))
        v.setOnClickPendingIntent(R.id.tab_events, tabIntent(context, widgetId, TAB_EVENTS))
        v.setOnClickPendingIntent(R.id.tab_tasks, tabIntent(context, widgetId, TAB_TASKS))
        v.setOnClickPendingIntent(R.id.tab_nudges, tabIntent(context, widgetId, TAB_NUDGES))
        return v
    }

    private fun nextUp(
        context: Context,
        v: RemoteViews,
        widgetId: Int,
        s: BriefingSnapshot,
        time: DateTimeFormatter,
    ) {
        val e = s.nextEvent
        v.setOnClickPendingIntent(R.id.next_card, openApp(context, widgetId, 6, "/schedule"))
        v.setOnClickPendingIntent(R.id.next_secondary, openApp(context, widgetId, 8, "/", "chat"))
        if (e == null) {
            v.setViewVisibility(R.id.next_pill, View.GONE)
            v.setTextViewText(R.id.next_time, "Nothing scheduled this week")
            val task = s.focusTasks.firstOrNull()
            if (task != null) {
                v.setTextViewText(R.id.next_title, task.title)
                v.setTextViewText(R.id.next_desc, taskLine(task, s, time))
                v.setViewVisibility(R.id.next_desc, View.VISIBLE)
            } else {
                v.setTextViewText(R.id.next_title, "Your day is clear")
                v.setTextViewText(R.id.next_desc, "Ask Exa to plan something, or enjoy the space.")
                v.setViewVisibility(R.id.next_desc, View.VISIBLE)
            }
            v.setImageViewResource(R.id.next_primary_icon, R.drawable.ic_widget_task)
            v.setTextViewText(R.id.next_primary_label, "Open tasks")
            v.setOnClickPendingIntent(R.id.next_primary, openApp(context, widgetId, 7, "/tasks"))
            return
        }

        val untilStart = Duration.between(s.now, e.start)
        val minutes = ceilMinutes(untilStart)
        when {
            !e.start.isAfter(s.now) -> pill(v, R.id.next_pill, "Happening now", "green")
            minutes <= 60 -> pill(v, R.id.next_pill, "Starts in ${plural(minutes.toInt(), "min")}", "red")
            e.start.toLocalDate() == s.now.toLocalDate() ->
                pill(v, R.id.next_pill, "Starts at ${e.start.format(time)}", "lavender")
            e.start.toLocalDate() == s.now.toLocalDate().plusDays(1) ->
                pill(v, R.id.next_pill, "Tomorrow", "lavender")
            else -> pill(
                v, R.id.next_pill,
                e.start.format(DateTimeFormatter.ofPattern("EEE d", Locale.getDefault())),
                "lavender",
            )
        }
        v.setViewVisibility(R.id.next_pill, View.VISIBLE)

        val span = buildString {
            if (e.start.toLocalDate() != s.now.toLocalDate()) {
                append(e.start.format(DateTimeFormatter.ofPattern("EEE, MMM d", Locale.getDefault())))
                append(" • ")
            }
            append(e.start.format(time))
            if (e.end != null && e.end.isAfter(e.start)) append(" – ").append(e.end.format(time))
            val place = e.location
            if (place != null) {
                append(" • ")
                append(if (anyLink.matches(place)) "Video call" else place)
            }
        }
        v.setTextViewText(R.id.next_time, span)
        v.setTextViewText(R.id.next_title, e.title)
        val desc = e.description
            ?.replace(anyLink, "")
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        v.setTextViewText(R.id.next_desc, desc ?: "")
        v.setViewVisibility(R.id.next_desc, if (desc != null) View.VISIBLE else View.GONE)

        val link = joinLink.find(listOfNotNull(e.location, e.description).joinToString(" "))
            ?.value?.trimEnd('.', ',', ')', '>')
        if (link != null) {
            v.setImageViewResource(R.id.next_primary_icon, R.drawable.ic_widget_video)
            v.setTextViewText(R.id.next_primary_label, joinLabel(link))
            v.setOnClickPendingIntent(R.id.next_primary, openUrl(context, widgetId, link))
        } else {
            v.setImageViewResource(R.id.next_primary_icon, R.drawable.ic_widget_event)
            v.setTextViewText(R.id.next_primary_label, "Open schedule")
            v.setOnClickPendingIntent(R.id.next_primary, openApp(context, widgetId, 7, "/schedule"))
        }
    }

    /** One list line; a [header] is a day or group label, not an item. */
    private data class Row(
        val title: String,
        val sub: String = "",
        val meta: String = "",
        val dot: String = "lavender",
        val header: Boolean = false,
    )

    private fun list(
        context: Context,
        v: RemoteViews,
        widgetId: Int,
        tab: Int,
        s: BriefingSnapshot,
        time: DateTimeFormatter,
        listSpace: Int,
        scrollTop: Boolean,
    ) {
        val route: String
        val empty: String
        val rows = mutableListOf<Row>()
        when (tab) {
            TAB_EVENTS -> {
                route = "/schedule"
                empty = "Nothing on your calendar in the next two weeks."
                var day: LocalDate? = null
                for (e in s.upcomingEvents) {
                    // An event that began yesterday and is still running sits
                    // under today.
                    val date = maxOf(e.start.toLocalDate(), s.now.toLocalDate())
                    if (date != day) {
                        day = date
                        rows += Row(dayLabel(date, s), header = true)
                    }
                    val ongoing = !e.start.isAfter(s.now) && e.effectiveEnd.isAfter(s.now)
                    val past = !e.effectiveEnd.isAfter(s.now)
                    rows += Row(
                        title = e.title,
                        sub = when {
                            e.allDay -> "All day"
                            ongoing -> "Now" + (e.location?.let { " • $it" } ?: "")
                            else -> e.location ?: durationText(e)
                        },
                        meta = if (e.allDay) "" else e.start.format(time),
                        dot = when {
                            ongoing -> "green"
                            past -> "muted"
                            else -> "lavender"
                        },
                    )
                }
            }
            TAB_TASKS -> {
                route = "/tasks"
                empty = "No open tasks."
                if (s.focusTasks.isNotEmpty()) rows += Row("Focus", header = true)
                for (t in s.focusTasks) {
                    rows += Row(
                        title = t.title,
                        sub = taskLine(t, s, time),
                        meta = if (t.highPriority) t.priority else "",
                        dot = when {
                            t.overdue -> "red"
                            t.highPriority -> "amber"
                            else -> "green"
                        },
                    )
                }
                if (s.otherTasks.isNotEmpty()) rows += Row("Other open tasks", header = true)
                for (t in s.otherTasks) {
                    rows += Row(title = t.title, sub = taskLine(t, s, time))
                }
            }
            else -> {
                route = "/reminders"
                empty = "No reminders in the next 30 days."
                var day: LocalDate? = null
                for (r in s.upcomingReminders) {
                    val date = r.at.toLocalDate()
                    if (date != day) {
                        day = date
                        rows += Row(dayLabel(date, s), header = true)
                    }
                    rows += Row(
                        title = r.title,
                        sub = if (r.at.isBefore(s.endOfDay)) {
                            "In ${durationText(Duration.between(s.now, r.at))}"
                        } else {
                            ""
                        },
                        meta = r.at.format(time),
                        dot = "amber",
                    )
                }
            }
        }
        val shown = rows.take(MAX_LIST_ROWS)

        v.setTextViewText(R.id.list_empty, empty)
        v.setTextViewText(R.id.list_more, "Open in Exa")
        val open = openApp(context, widgetId, 9, route)
        v.setOnClickPendingIntent(R.id.list_more, open)
        v.setOnClickPendingIntent(R.id.list_empty, open)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // A real scrolling list. The items travel inside this update, so
            // no RemoteViewsService is needed; taps go through one template
            // intent that each row's (empty) fill-in intent triggers.
            val items = RemoteViews.RemoteCollectionItems.Builder()
                .setViewTypeCount(2)
            shown.forEachIndexed { i, row ->
                val r = rowViews(context, row)
                if (!row.header) r.setOnClickFillInIntent(R.id.row, Intent())
                items.addItem(i.toLong(), r)
            }
            v.setViewVisibility(R.id.list_rows, View.GONE)
            v.setViewVisibility(R.id.list_view, View.VISIBLE)
            v.setRemoteAdapter(R.id.list_view, items.build())
            v.setPendingIntentTemplate(R.id.list_view, rowTemplate(context, widgetId, route))
            v.setEmptyView(R.id.list_view, R.id.list_empty)
            if (scrollTop) v.setScrollPosition(R.id.list_view, 0)
            return
        }

        // Before Android 12 a collection needs a RemoteViewsService; show as
        // many whole rows as fit instead, leaving room for the "+N more" line
        // so it is never the thing that gets clipped.
        var maxRows = (listSpace / ROW_DP).coerceAtLeast(1)
        if (shown.size > maxRows) maxRows = ((listSpace - MORE_DP) / ROW_DP).coerceAtLeast(1)
        val kept = shown.take(maxRows)
        v.setViewVisibility(R.id.list_view, View.GONE)
        v.setViewVisibility(R.id.list_rows, View.VISIBLE)
        v.removeAllViews(R.id.list_rows)
        for (row in kept) {
            val r = rowViews(context, row)
            if (!row.header) r.setOnClickPendingIntent(R.id.row, open)
            v.addView(R.id.list_rows, r)
        }
        v.setViewVisibility(R.id.list_empty, if (rows.isEmpty()) View.VISIBLE else View.GONE)
        val hidden = rows.count { !it.header } - kept.count { !it.header }
        if (hidden > 0) v.setTextViewText(R.id.list_more, "+$hidden more • Open in Exa")
    }

    private fun rowViews(context: Context, row: Row): RemoteViews {
        if (row.header) {
            return RemoteViews(context.packageName, R.layout.widget_briefing_section).apply {
                setTextViewText(R.id.section_label, row.title.uppercase(Locale.getDefault()))
            }
        }
        return RemoteViews(context.packageName, R.layout.widget_briefing_row).apply {
            setTextViewText(R.id.row_title, row.title)
            setTextViewText(R.id.row_sub, row.sub)
            setViewVisibility(R.id.row_sub, if (row.sub.isEmpty()) View.GONE else View.VISIBLE)
            setTextViewText(R.id.row_meta, row.meta)
            setImageViewResource(R.id.row_dot, dotRes(row.dot))
            if (row.dot == "muted") setTextColor(R.id.row_title, TEXT_MUTED)
        }
    }

    private fun dayLabel(date: LocalDate, s: BriefingSnapshot): String {
        val today = s.now.toLocalDate()
        return when (date) {
            today -> "Today"
            today.plusDays(1) -> "Tomorrow"
            else -> date.format(DateTimeFormatter.ofPattern("EEE, MMM d", Locale.getDefault()))
        }
    }

    /** Rows per list, headers included; keeps the update parcel small. */
    private const val MAX_LIST_ROWS = 80

    /** Rough heights (dp) of the fixed parts above the tab content. */
    private const val ABOVE_LIST_DP = 378
    private const val ROW_DP = 46
    private const val MORE_DP = 22

    /**
     * The widget's real height in dp. One UI reports the grid cell size and
     * then scales the whole widget by `hsResizeRatio` to fit its grid, so the
     * reported height overstates the space by that factor (652dp drawn at
     * 0.83 on the S25). Other launchers do not send the key.
     */
    private fun heightDp(manager: AppWidgetManager, widgetId: Int): Int {
        val options = manager.getAppWidgetOptions(widgetId)
        val reported = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
        val ratio = options.getFloat("hsResizeRatio", 1f).takeIf { it in 0.3f..1f } ?: 1f
        return (reported * ratio).toInt()
    }

    // ---------------------------------------------------------------- words

    private fun greetingFor(now: ZonedDateTime) = when (now.hour) {
        in 5..11 -> "Good morning"
        in 12..16 -> "Good afternoon"
        else -> "Good evening"
    }

    private fun subtitle(s: BriefingSnapshot): String {
        val left = s.eventsLeftToday
        val first = if (left.isEmpty()) {
            if (s.todayEvents.isEmpty()) "No events today" else "No more events today"
        } else {
            "${plural(left.size, "event")} left • ${durationText(s.eventTimeLeft)} booked"
        }
        return if (s.doneToday > 0) "$first • ${s.doneToday} done today" else first
    }

    private fun briefingText(s: BriefingSnapshot): CharSequence {
        val b = SpannableStringBuilder("You have ")
        val events = s.todayEvents.size
        if (events > 0) strong(b, plural(events, "event"), ACCENT) else b.append("no events")
        b.append(" today, ")
        val focus = s.focusTasks.size
        if (focus > 0) {
            strong(b, plural(focus, "focus task"), if (s.overdueCount > 0) RED else GREEN)
        } else {
            b.append("no urgent tasks")
        }
        b.append(", and ")
        val reminders = s.remindersToday.size
        when {
            s.pendingApprovals > 0 -> strong(b, plural(s.pendingApprovals, "pending approval"), AMBER)
            reminders > 0 -> {
                strong(b, plural(reminders, "reminder"), AMBER)
                b.append(" still to come")
            }
            else -> b.append("no reminders left")
        }
        b.append(".")
        when {
            s.overlaps > 0 -> b.append(
                " ${plural(s.overlaps, "schedule overlap")} " +
                    "${if (s.overlaps == 1) "needs" else "need"} a look.",
            )
            s.overdueCount > 0 -> b.append(
                " ${plural(s.overdueCount, "task")} ${if (s.overdueCount == 1) "is" else "are"} overdue.",
            )
            events > 0 && s.eventsLeftToday.isEmpty() -> b.append(" Your calendar is clear for the rest of the day.")
        }
        return b
    }

    private fun eventTileLine(s: BriefingSnapshot, time: DateTimeFormatter): Pair<String, Int> {
        val e = s.eventsLeftToday.firstOrNull() ?: return if (s.todayEvents.isEmpty()) {
            "Nothing scheduled" to TEXT_SOFT
        } else {
            "Done for today" to TEXT_SOFT
        }
        if (!e.start.isAfter(s.now)) return "Now: ${e.title}" to GREEN
        val minutes = ceilMinutes(Duration.between(s.now, e.start))
        return if (minutes <= 60) {
            "Next in ${minutes}m" to TEXT_SOFT
        } else {
            "Next at ${e.start.format(time)}" to TEXT_SOFT
        }
    }

    private fun taskLine(t: WidgetTask, s: BriefingSnapshot, time: DateTimeFormatter): String {
        val due = t.due
        return when {
            due == null -> "${t.priority} priority"
            t.overdue -> "Overdue • was due " + if (due.toLocalDate() == s.now.toLocalDate()) {
                due.format(time)
            } else {
                due.format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault()))
            }
            t.dueToday -> if (due.toLocalTime().toSecondOfDay() == 0) {
                "Due today"
            } else {
                "Due today at ${due.format(time)}"
            }
            else -> "Due " + due.format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault()))
        }
    }

    private fun joinLabel(link: String) = when {
        link.contains("meet.google.com", true) -> "Join Google Meet"
        link.contains("zoom.us", true) -> "Join Zoom"
        link.contains("teams.", true) -> "Join Teams"
        link.contains("webex.com", true) -> "Join Webex"
        else -> "Join call"
    }

    private fun durationText(e: WidgetEvent): String =
        if (e.end != null && e.end.isAfter(e.start)) durationText(Duration.between(e.start, e.end)) else ""

    private fun durationText(d: Duration): String {
        val total = ceilMinutes(d)
        val h = total / 60
        val m = total % 60
        return when {
            h == 0L -> "${m}m"
            m == 0L -> "${h}h"
            else -> "${h}h ${m}m"
        }
    }

    private fun ceilMinutes(d: Duration): Long {
        val seconds = d.seconds.coerceAtLeast(0)
        return (seconds + 59) / 60
    }

    private fun plural(n: Int, word: String) = if (n == 1) "1 $word" else "$n ${word}s"

    private fun strong(b: SpannableStringBuilder, text: String, color: Int) {
        val start = b.length
        b.append(text)
        b.setSpan(ForegroundColorSpan(color), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        b.setSpan(StyleSpan(Typeface.BOLD), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun timeFormatter(context: Context): DateTimeFormatter =
        DateTimeFormatter.ofPattern(
            if (DateFormat.is24HourFormat(context)) "HH:mm" else "h:mm a",
            Locale.getDefault(),
        )

    // ---------------------------------------------------------- view helpers

    private fun pill(v: RemoteViews, id: Int, text: String, tone: String) {
        v.setTextViewText(id, text)
        val (bg, fg) = when (tone) {
            "green" -> R.drawable.widget_pill_green to GREEN
            "amber" -> R.drawable.widget_pill_amber to AMBER
            "red" -> R.drawable.widget_pill_red to RED
            else -> R.drawable.widget_pill_lavender to ACCENT
        }
        v.setInt(id, "setBackgroundResource", bg)
        v.setTextColor(id, fg)
    }

    private fun dot(v: RemoteViews, id: Int, tone: String) =
        v.setImageViewResource(id, dotRes(tone))

    private fun dotRes(tone: String) = when (tone) {
        "green" -> R.drawable.widget_dot_green
        "amber" -> R.drawable.widget_dot_amber
        "red" -> R.drawable.widget_dot_red
        "muted" -> R.drawable.widget_dot_muted
        else -> R.drawable.widget_dot_lavender
    }

    private fun tabLabel(v: RemoteViews, id: Int, text: String, selected: Boolean) {
        v.setTextViewText(id, text)
        v.setInt(id, "setBackgroundResource", if (selected) R.drawable.widget_tab_selected else 0)
        v.setTextColor(id, if (selected) TEXT else TEXT_MUTED)
    }

    // -------------------------------------------------------------- intents

    /**
     * Opens Exa on [route] (and optionally a launch [action]) through the
     * same `exa_route` / `exa_action` extras the bubble and notifications use.
     */
    private fun openApp(
        context: Context,
        widgetId: Int,
        slot: Int,
        route: String,
        action: String? = null,
    ): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .putExtra("exa_route", route)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (action != null) intent.putExtra("exa_action", action)
        return PendingIntent.getActivity(
            context,
            requestCode(widgetId, slot),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * The list's shared tap target. Mutable on purpose: a collection row's
     * fill-in intent can only be merged into a mutable template.
     */
    private fun rowTemplate(context: Context, widgetId: Int, route: String): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode(widgetId, 15),
            Intent(context, MainActivity::class.java)
                .putExtra("exa_route", route)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    private fun openUrl(context: Context, widgetId: Int, url: String): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode(widgetId, 10),
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun tabIntent(context: Context, widgetId: Int, tab: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            requestCode(widgetId, 11 + tab),
            Intent(context, BriefingWidgetProvider::class.java)
                .setAction(BriefingWidgetProvider.ACTION_TAB)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                .putExtra(BriefingWidgetProvider.EXTRA_TAB, tab),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun requestCode(widgetId: Int, slot: Int) = 0x5000 + widgetId * 16 + slot

    // ------------------------------------------------------------ refreshing

    /**
     * Arms one non-waking alarm for the next moment the widget's words would
     * change: a minute tick while an event is under an hour away (the
     * countdown), otherwise the next event start/end, reminder, midnight, or
     * a quarter-hour backstop. Non-waking: a widget nobody can see does not
     * need to be redrawn, and the alarm fires as soon as the screen is on.
     */
    private fun scheduleRefresh(context: Context, s: BriefingSnapshot?) {
        val nowMs = System.currentTimeMillis()
        val at = if (s == null) nowMs + 60_000 else nextRefreshAt(s)
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = refreshIntent(context)
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()) {
                alarms.setExact(AlarmManager.RTC, at, pending)
            } else {
                alarms.setWindow(AlarmManager.RTC, at, 60_000, pending)
            }
        } catch (e: SecurityException) {
            alarms.set(AlarmManager.RTC, at, pending)
        }
    }

    internal fun nextRefreshAt(s: BriefingSnapshot): Long {
        val now = s.now
        val candidates = mutableListOf<ZonedDateTime>()
        candidates += now.truncatedTo(ChronoUnit.HOURS)
            .plusMinutes(((now.minute / 15) + 1) * 15L)
        candidates += s.endOfDay
        val horizon = s.endOfDay.plusDays(1)
        for (e in s.todayEvents + listOfNotNull(s.nextEvent)) {
            if (e.start.isAfter(now) && e.start.isBefore(horizon)) candidates += e.start
            if (e.effectiveEnd.isAfter(now) && e.effectiveEnd.isBefore(horizon)) candidates += e.effectiveEnd
        }
        s.upcomingReminders.forEach { if (it.at.isAfter(now)) candidates += it.at }
        val countdown = s.nextEvent?.let {
            it.start.isAfter(now) && Duration.between(now, it.start).toMinutes() < 61
        } ?: false
        if (countdown) candidates += now.truncatedTo(ChronoUnit.MINUTES).plusMinutes(1)
        // A second past the boundary, so "in 25 min" has already become 24.
        return candidates.minOf { it.toInstant().toEpochMilli() } + 1_000
    }

    private fun refreshIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            0x5001,
            Intent(context, BriefingWidgetProvider::class.java)
                .setAction(BriefingWidgetProvider.ACTION_REFRESH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun cancelRefresh(context: Context) {
        context.getSystemService(AlarmManager::class.java)?.cancel(refreshIntent(context))
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

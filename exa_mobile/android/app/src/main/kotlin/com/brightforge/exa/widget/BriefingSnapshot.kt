package com.brightforge.exa.widget

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.provider.ContactsContract
import android.util.Log
import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime

data class WidgetEvent(
    val title: String,
    val description: String?,
    val location: String?,
    val start: ZonedDateTime,
    val end: ZonedDateTime?,
) {
    /** A calendar import's all-day entry: midnight to midnight (or longer). */
    val allDay: Boolean
        get() = start.toLocalTime().toSecondOfDay() == 0 &&
            end != null && Duration.between(start, end).toHours() >= 23

    /** Events saved without an end still occupy a moment, not the day. */
    val effectiveEnd: ZonedDateTime
        get() = end?.takeIf { it.isAfter(start) } ?: start.plusMinutes(30)
}

data class WidgetTask(
    val title: String,
    val priority: String,
    val due: ZonedDateTime?,
    val overdue: Boolean,
    val dueToday: Boolean,
) {
    val highPriority: Boolean get() = priority == "High" || priority == "Urgent"
}

data class WidgetReminder(val title: String, val at: ZonedDateTime)

/** Everything one widget redraw shows, read in one pass. */
data class BriefingSnapshot(
    val now: ZonedDateTime,
    val ownerFirstName: String?,
    /** Today's timed and all-day events, by start. */
    val todayEvents: List<WidgetEvent>,
    /** Today's events and the next two weeks', by start (the Events list). */
    val upcomingEvents: List<WidgetEvent>,
    /** The event in progress, else the next one within a week. */
    val nextEvent: WidgetEvent?,
    /** Open tasks that are overdue, due today or high priority. */
    val focusTasks: List<WidgetTask>,
    /** The rest of the open tasks, soonest due first. */
    val otherTasks: List<WidgetTask>,
    val openTaskCount: Int,
    val doneToday: Int,
    /** Active reminders still to fire, soonest first (up to 30 days ahead). */
    val upcomingReminders: List<WidgetReminder>,
    val pendingApprovals: Int,
    val overlaps: Int,
) {
    val endOfDay: ZonedDateTime get() = now.toLocalDate().plusDays(1).atStartOfDay(now.zone)

    val remindersToday: List<WidgetReminder>
        get() = upcomingReminders.filter { it.at.isBefore(endOfDay) }

    val overdueCount: Int get() = focusTasks.count { it.overdue }
    val dueTodayCount: Int get() = focusTasks.count { it.dueToday && !it.overdue }

    val eventsLeftToday: List<WidgetEvent>
        get() = todayEvents.filter { !it.allDay && it.effectiveEnd.isAfter(now) }

    /** Event time still ahead today, ignoring overlaps between events. */
    val eventTimeLeft: Duration
        get() = eventsLeftToday.fold(Duration.ZERO) { sum, e ->
            val from = if (e.start.isAfter(now)) e.start else now
            val to = if (e.effectiveEnd.isBefore(endOfDay)) e.effectiveEnd else endOfDay
            if (to.isAfter(from)) sum.plus(Duration.between(from, to)) else sum
        }

    companion object {
        fun empty(now: ZonedDateTime, ownerFirstName: String?) = BriefingSnapshot(
            now, ownerFirstName, emptyList(), emptyList(), null, emptyList(),
            emptyList(), 0, 0, emptyList(), 0, 0,
        )
    }
}

/**
 * Reads the widget's data straight out of the app database.
 *
 * Read here rather than pushed from Dart because the rows change from many
 * places - the chat, scheduled jobs in the WorkManager and alarm isolates,
 * calendar imports - and a snapshot written by one of them would go stale the
 * moment another wrote. The database is the only thing they all agree on.
 *
 * The connection is opened read-only on purpose: a read-write Android
 * connection resets the journal mode on open, which would fight sqflite's
 * WAL setting. Read-only skips that and never takes a write lock.
 *
 * Dates are stored by Dart's `toIso8601String()`: local wall time with no
 * offset, or a trailing `Z` when the value was UTC. Both are parsed here, and
 * the SQL only narrows by date prefix - the real filtering is done after
 * parsing so the two forms cannot be mis-ordered by a string comparison.
 */
object BriefingReader {
    private const val TAG = "ExaBriefingWidget"
    private const val DB_NAME = "exa.db"

    /** How far ahead the Events and Nudges lists look. */
    private const val UPCOMING_DAYS = 14L
    private const val UPCOMING_REMINDER_DAYS = 30L

    private val offsetSuffix = Regex("(Z|[+-]\\d{2}:?\\d{2})$")

    /** Null when the database could not be read this time (retry later). */
    fun read(context: Context, now: ZonedDateTime): BriefingSnapshot? {
        val owner = ownerFirstName(context)
        val file = context.getDatabasePath(DB_NAME)
        if (!file.exists()) return BriefingSnapshot.empty(now, owner)
        val db = try {
            SQLiteDatabase.openDatabase(
                file.path,
                null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
            )
        } catch (e: SQLiteException) {
            Log.w(TAG, "Could not open the database", e)
            return null
        }
        return try {
            readFrom(db, now, owner)
        } catch (e: SQLiteException) {
            Log.w(TAG, "Could not read the database", e)
            null
        } finally {
            db.close()
        }
    }

    private fun readFrom(
        db: SQLiteDatabase,
        now: ZonedDateTime,
        owner: String?,
    ): BriefingSnapshot {
        val zone = now.zone
        val today = now.toLocalDate()
        val startOfDay = today.atStartOfDay(zone)
        val endOfDay = today.plusDays(1).atStartOfDay(zone)

        // Events: from a couple of days back by date prefix (a UTC value can
        // sit on the neighbouring date) to two weeks ahead for the list.
        val events = mutableListOf<WidgetEvent>()
        db.rawQuery(
            """
            SELECT title, description, location, start_at, end_at, status
            FROM schedule_items
            WHERE start_at >= ? AND start_at < ?
            """.trimIndent(),
            arrayOf(today.minusDays(2).toString(), today.plusDays(16).toString()),
        ).use { c ->
            while (c.moveToNext()) {
                val status = c.getString(5) ?: "Confirmed"
                if (status.startsWith("Cancel", ignoreCase = true) ||
                    status.equals("Declined", ignoreCase = true)
                ) continue
                val start = parseTime(c.getString(3), zone) ?: continue
                events += WidgetEvent(
                    title = c.getString(0) ?: continue,
                    description = c.getString(1)?.trim()?.takeIf { it.isNotEmpty() },
                    location = c.getString(2)?.trim()?.takeIf { it.isNotEmpty() },
                    start = start,
                    end = parseTime(c.getString(4), zone),
                )
            }
        }
        events.sortBy { it.start.toInstant() }
        val todayEvents = events.filter {
            it.start.isBefore(endOfDay) && it.effectiveEnd.isAfter(startOfDay)
        }
        val listEnd = endOfDay.plusDays(UPCOMING_DAYS)
        val upcomingEvents = events.filter {
            it.start.isBefore(listEnd) && it.effectiveEnd.isAfter(startOfDay)
        }
        val weekEnd = endOfDay.plusDays(7)
        val nextEvent = events.firstOrNull {
            !it.allDay && it.effectiveEnd.isAfter(now) && it.start.isBefore(weekEnd)
        }

        // Tasks: everything open, plus what was finished recently enough to
        // count as "done today".
        val focus = mutableListOf<WidgetTask>()
        val other = mutableListOf<WidgetTask>()
        var openCount = 0
        var doneToday = 0
        db.rawQuery(
            """
            SELECT title, status, priority, due_at, completed_at
            FROM tasks
            WHERE status NOT IN ('Completed', 'Canceled')
               OR (status = 'Completed' AND completed_at >= ?)
            """.trimIndent(),
            arrayOf(today.minusDays(1).toString()),
        ).use { c ->
            while (c.moveToNext()) {
                val status = c.getString(1) ?: "Pending"
                if (status == "Completed") {
                    val done = parseTime(c.getString(4), zone)
                    if (done != null && !done.isBefore(startOfDay)) doneToday++
                    continue
                }
                openCount++
                val dueText = c.getString(3)
                val due = parseTime(dueText, zone)
                val dateOnly = dueText != null && dueText.trim().length == 10
                val overdue = due != null &&
                    if (dateOnly) due.toLocalDate().isBefore(today) else due.isBefore(now)
                val task = WidgetTask(
                    title = c.getString(0) ?: continue,
                    priority = c.getString(2) ?: "Normal",
                    due = due,
                    overdue = overdue || status == "Overdue",
                    dueToday = due != null && due.toLocalDate() == today,
                )
                if (task.overdue || task.dueToday || task.highPriority) focus += task else other += task
            }
        }
        // Overdue first, then by due time, then urgent before high.
        focus.sortWith(
            compareBy<WidgetTask>(
                { !it.overdue },
                { it.due == null },
                { it.due },
                { it.priority != "Urgent" },
            ),
        )
        other.sortWith(compareBy<WidgetTask>({ it.due == null }, { it.due }, { it.title }))

        val reminders = mutableListOf<WidgetReminder>()
        db.rawQuery(
            """
            SELECT title, remind_at FROM reminders
            WHERE status = 'Active' AND remind_at >= ? AND remind_at < ?
            """.trimIndent(),
            arrayOf(today.minusDays(1).toString(), today.plusDays(UPCOMING_REMINDER_DAYS + 2).toString()),
        ).use { c ->
            while (c.moveToNext()) {
                val at = parseTime(c.getString(1), zone) ?: continue
                if (at.isBefore(now) || !at.isBefore(endOfDay.plusDays(UPCOMING_REMINDER_DAYS))) continue
                reminders += WidgetReminder(c.getString(0) ?: continue, at)
            }
        }
        reminders.sortBy { it.at.toInstant() }

        val approvals = try {
            db.rawQuery(
                "SELECT COUNT(*) FROM pending_calendar_events WHERE status = 'Pending'",
                null,
            ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }
        } catch (_: SQLiteException) {
            0 // Older database without the table.
        }

        return BriefingSnapshot(
            now = now,
            ownerFirstName = owner,
            todayEvents = todayEvents,
            upcomingEvents = upcomingEvents,
            nextEvent = nextEvent,
            focusTasks = focus,
            otherTasks = other,
            openTaskCount = openCount,
            doneToday = doneToday,
            upcomingReminders = reminders,
            pendingApprovals = approvals,
            overlaps = countOverlaps(todayEvents.filter { !it.allDay }),
        )
    }

    /** Pairs of timed events that share any minute. */
    internal fun countOverlaps(events: List<WidgetEvent>): Int {
        var count = 0
        for (i in events.indices) {
            for (j in i + 1 until events.size) {
                val a = events[i]
                val b = events[j]
                val aEnd = a.end?.takeIf { it.isAfter(a.start) } ?: a.start
                val bEnd = b.end?.takeIf { it.isAfter(b.start) } ?: b.start
                val shared = a.start.isBefore(bEnd) && b.start.isBefore(aEnd)
                if (shared || a.start.isEqual(b.start)) count++
            }
        }
        return count
    }

    internal fun parseTime(raw: String?, zone: ZoneId): ZonedDateTime? {
        val text = raw?.trim()?.replace(' ', 'T') ?: return null
        if (text.isEmpty()) return null
        return try {
            when {
                text.length == 10 -> LocalDate.parse(text).atStartOfDay(zone)
                offsetSuffix.containsMatchIn(text.substring(10)) ->
                    OffsetDateTime.parse(text).atZoneSameInstant(zone)
                else -> LocalDateTime.parse(text).atZone(zone)
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * The phone owner's first name from the "Me" contact, when Exa already
     * holds the contacts permission (granted for phone access). The app has
     * no name setting of its own, and the widget never asks for one.
     */
    private fun ownerFirstName(context: Context): String? {
        if (context.checkSelfPermission(Manifest.permission.READ_CONTACTS) !=
            PackageManager.PERMISSION_GRANTED
        ) return null
        return try {
            context.contentResolver.query(
                ContactsContract.Profile.CONTENT_URI,
                arrayOf(ContactsContract.Profile.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.trim()?.split(Regex("\\s+"))?.firstOrNull()
                        ?.takeIf { it.isNotEmpty() && it.any(Char::isLetter) }
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            null
        }
    }
}

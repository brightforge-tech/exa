package com.brightforge.exa.messaging

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * The chat apps Exa knows how to read, and which of them the user has
 * actually allowed.
 *
 * The allowlist lives here, in SharedPreferences, and **not** in SQLite. A
 * [ExaNotificationListener] is started by the system whenever it likes,
 * including with the app process otherwise dead and no Flutter engine in
 * existence, so it has to decide whether to keep a notification without
 * asking Dart anything. Two sources of truth for "may Exa read WhatsApp"
 * would drift silently in the direction that matters least — reading more
 * than the user agreed to.
 *
 * Nothing is allowed by default. Granting notification access is a
 * device-wide capability (every OTP, every banking alert, every message from
 * every app), so the grant and the decision about what to *keep* are
 * deliberately separate steps.
 */
object ChatPackages {
    const val PREFS = "exa_messaging"
    const val KEY_ALLOWED = "allowed_packages"
    const val KEY_CAPTURE_ENABLED = "capture_enabled"

    /** Channel keys, mirrored in Dart's `MessageChannels`. */
    const val WHATSAPP = "whatsapp"
    const val WHATSAPP_BUSINESS = "whatsapp_business"
    const val SIGNAL = "signal"
    const val TELEGRAM = "telegram"
    const val SMS_GOOGLE = "sms"

    // Work sources. Teams direct messages arrive as MessagingStyle; Teams
    // channel posts, Outlook and Gmail arrive as plain notifications, which
    // the listener already captures through its flat-text fallback (title =
    // sender/subject, text = preview). Enough to spot a task, a deadline or
    // a meeting; the full body needs the app or an account, which is a later
    // enrichment.
    const val TEAMS = "teams"
    const val OUTLOOK = "outlook"
    const val GMAIL = "gmail"

    /**
     * Package → channel key. The notification listener reads WhatsApp,
     * Signal, Telegram and SMS through the identical `MessagingStyle` API,
     * so supporting the others is a map entry rather than a feature.
     *
     * `MessagingChannelsTest` pins this list against the Dart catalogue —
     * the two copies exist for a reason (see the class comment) but they may
     * not disagree.
     */
    val CHANNEL_BY_PACKAGE: Map<String, String> = mapOf(
        "com.whatsapp" to WHATSAPP,
        "com.whatsapp.w4b" to WHATSAPP_BUSINESS,
        "org.thoughtcrime.securesms" to SIGNAL,
        "org.telegram.messenger" to TELEGRAM,
        "com.google.android.apps.messaging" to SMS_GOOGLE,
        "com.microsoft.teams" to TEAMS,
        "com.microsoft.office.outlook" to OUTLOOK,
        "com.google.android.gm" to GMAIL,
    )

    fun channelFor(packageName: String): String? =
        CHANNEL_BY_PACKAGE[packageName]

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Whether capture is switched on at all. Separate from the allowlist so
     * turning Exa's reading off is one action the user can take in a hurry,
     * without losing which apps they had chosen.
     */
    fun isCaptureEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CAPTURE_ENABLED, false)

    fun setCaptureEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_CAPTURE_ENABLED, enabled).apply()
    }

    fun allowedPackages(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_ALLOWED, emptySet()) ?: emptySet()

    fun setAllowedPackages(context: Context, packages: Collection<String>) {
        // Only packages this build knows how to parse, so an arbitrary app
        // can never be added to the set by a malformed call from Dart.
        val known = packages.filter { CHANNEL_BY_PACKAGE.containsKey(it) }
        prefs(context).edit()
            .putStringSet(KEY_ALLOWED, known.toSet())
            .apply()
    }

    /**
     * The single question the listener asks per notification: keep it, or
     * drop it without reading anything out of it.
     */
    fun shouldCapture(context: Context, packageName: String): Boolean =
        isCaptureEnabled(context) &&
            CHANNEL_BY_PACKAGE.containsKey(packageName) &&
            allowedPackages(context).contains(packageName)

    // ------------------------------------------------ media probe matrix --

    /**
     * The per-package media-probe matrix, persisted so it survives an adb
     * session: the spike's point is a decision input for the media feature,
     * and logcat scrolls away. The listener process and the settings screen
     * read the same prefs file, so the matrix outlives the service just
     * like the spool outlives the engine.
     */
    const val KEY_MEDIA_PROBE_REPORT = "media_probe_report"

    /** Records per package kept; newest last, oldest evicted first. */
    const val MAX_PROBE_RECORDS_PER_PACKAGE = 8

    /**
     * Hard ceiling on the stored document, so a probe can never grow
     * SharedPreferences. The per-package cap alone keeps it well under
     * this; the constant is the seatbelt, and whole packages are dropped if
     * it ever mattered.
     */
    private const val MAX_PROBE_REPORT_CHARS = 60_000

    /**
     * Probe work runs on the listener's worker thread while Settings reads
     * on the main one; SharedPreferences itself is thread-safe, but the
     * read-modify-write below is not without this.
     */
    private val probeReportLock = Any()

    /**
     * Records one probe outcome for one package. Never throws - the caller
     * is the listener's probe worker, and an exception escaping there is a
     * crashed process watching the notification shade. A package outside
     * the known map is refused for the same reason [setAllowedPackages]
     * is: the report must not become a place arbitrary apps can be written.
     */
    fun recordMediaProbe(
        context: Context,
        packageName: String,
        origin: String,
        scheme: String?,
        mimeType: String?,
        bytesRead: Int,
        failure: String,
    ) {
        if (!CHANNEL_BY_PACKAGE.containsKey(packageName)) return
        synchronized(probeReportLock) {
            try {
                val store = prefs(context)
                val document = try {
                    JSONObject(store.getString(KEY_MEDIA_PROBE_REPORT, null) ?: "{}")
                } catch (e: Exception) {
                    JSONObject()
                }
                var device = document.optJSONObject("device")
                if (device == null || device.length() == 0) {
                    // The tested surface, stated once: URI readability is
                    // app- and OEM-specific, so a matrix without the device
                    // it was probed on is a number without units.
                    device = JSONObject()
                    device.put("release", Build.VERSION.RELEASE)
                    device.put("manufacturer", Build.MANUFACTURER)
                    device.put("model", Build.MODEL)
                    device.put("api", Build.VERSION.SDK_INT)
                }
                val packages = document.optJSONObject("packages") ?: JSONObject()
                val records = packages.optJSONArray(packageName) ?: JSONArray()
                val record = JSONObject()
                    .put("origin", origin)
                    .put("bytes", bytesRead)
                    .put("failure", failure)
                    .put("at", System.currentTimeMillis())
                // Absent rather than null-valued when unknown: the document
                // stays compact and the Dart side reads a missing key as
                // "no answer" anyway. Never a URI - see NotificationMedia.
                if (!scheme.isNullOrEmpty()) record.put("scheme", scheme)
                if (!mimeType.isNullOrEmpty()) record.put("mime_type", mimeType)
                records.put(record)
                while (records.length() > MAX_PROBE_RECORDS_PER_PACKAGE) {
                    records.remove(0)
                }
                packages.put(packageName, records)
                document.put("device", device)
                document.put("packages", packages)

                var encoded = document.toString()
                while (encoded.length > MAX_PROBE_REPORT_CHARS && packages.length() > 0) {
                    packages.remove(packages.keys().next())
                    encoded = document.toString()
                }
                if (encoded.length <= MAX_PROBE_REPORT_CHARS) {
                    store.edit().putString(KEY_MEDIA_PROBE_REPORT, encoded).apply()
                }
            } catch (e: Exception) {
                // A lost probe record is noise; the probe already logged it.
            }
        }
    }

    /**
     * The matrix, flattened to rows for the `mediaProbeReport` channel
     * method: one row per probe record, with the device facts repeated on
     * every row so one flat list crosses the channel intact. The field
     * names are shared with `MediaProbeRecord` in messaging_bridge.dart and
     * pinned by media_probe_report_test.dart.
     */
    fun mediaProbeReport(context: Context): List<Map<String, Any?>> {
        val raw = prefs(context).getString(KEY_MEDIA_PROBE_REPORT, null) ?: return emptyList()
        return try {
            val document = JSONObject(raw)
            val device = document.optJSONObject("device") ?: JSONObject()
            val packages = document.optJSONObject("packages") ?: JSONObject()
            val rows = mutableListOf<Map<String, Any?>>()
            for (packageName in packages.keys()) {
                val records = packages.optJSONArray(packageName) ?: continue
                for (i in 0 until records.length()) {
                    val record = records.optJSONObject(i) ?: continue
                    rows.add(
                        mapOf(
                            "package" to packageName,
                            "origin" to record.optString("origin"),
                            "scheme" to record.optString("scheme").takeIf { it.isNotEmpty() },
                            "mime_type" to record.optString("mime_type").takeIf { it.isNotEmpty() },
                            "bytes" to record.optInt("bytes", 0),
                            "failure" to record.optString("failure"),
                            "at" to record.optLong("at", 0L),
                            "device_release" to device.optString("release"),
                            "device_manufacturer" to device.optString("manufacturer"),
                            "device_model" to device.optString("model"),
                            "device_api" to device.optInt("api", 0),
                        ),
                    )
                }
            }
            rows
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** Known chat apps that are actually installed, for the settings list. */
    fun installedSupported(context: Context): List<Map<String, Any>> {
        val manager = context.packageManager
        val allowed = allowedPackages(context)
        return CHANNEL_BY_PACKAGE.entries.mapNotNull { (pkg, channel) ->
            val label = try {
                manager.getApplicationLabel(
                    manager.getApplicationInfo(pkg, 0),
                ).toString()
            } catch (e: PackageManager.NameNotFoundException) {
                return@mapNotNull null
            }
            mapOf(
                "package" to pkg,
                "channel" to channel,
                "label" to label,
                "allowed" to allowed.contains(pkg),
            )
        }
    }
}

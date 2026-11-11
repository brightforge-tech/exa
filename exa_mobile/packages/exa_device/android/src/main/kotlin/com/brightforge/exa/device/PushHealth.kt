package com.brightforge.exa.device

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.PowerManager
import android.util.Log
import java.util.concurrent.TimeUnit

/**
 * The health of Google Play services' push connection, and the one repair
 * Exa can apply to it.
 *
 * ### Why this exists
 *
 * On the S8+ (LineageOS 23.2 + MindTheGapps, Play services 26.33) the push
 * socket to mtalk.google.com dies after a Wi-Fi blip or a deep-Doze entry,
 * Play services makes exactly one reconnect attempt and then schedules
 * nothing else - for sixteen hours, through screen-ons, Doze exits and a
 * manual Wi-Fi off/on. Every FCM-driven app (Teams, Outlook, Gmail) goes
 * silent until a reboot, and then the backlog lands all at once. Play
 * services was never killed, frozen or short of memory; it is a stuck
 * connection state machine. Only restarting the process clears it.
 *
 * ### How it reads the state
 *
 * `dumpsys activity service GcmService` is Play services dumping its own
 * connection status. `dumpsys` is an ordinary binary any app may execute;
 * the dump itself is gated on the caller holding `android.permission.DUMP`,
 * which Exa gets from the provisioning script. Without it the output is a
 * permission denial and [status] says so rather than guessing.
 *
 * ### How it repairs
 *
 * As Device Owner, hiding a package kills its processes and unhiding it
 * lets them relaunch on demand - the same effect as Settings > Force stop,
 * which is the manual fix. Play services is back within seconds because
 * every FCM client rebinds to it. The unhide is retried and verified: a
 * Play services left hidden would be far worse than a dead socket.
 */
object PushHealth {
    private const val TAG = "ExaPushHealth"
    const val PLAY_SERVICES = "com.google.android.gms"

    private const val DUMP_TIMEOUT_S = 10L
    private const val HIDE_HOLD_MS = 1500L

    private val logLine = Regex("""^\s*\d\d-\d\d \d\d:\d\d:\d\d\.\d+ net=""")
    private val clientConnected = Regex("""Is client connected:\s*(true|false)""")
    private val connects = Regex("""\bconnects=(\d+)""")
    private val endpoint = Regex("""^\s*connected=(\S+)""", RegexOption.MULTILINE)
    private val activeNetwork = Regex("""^\s*Active:\s+(.+)$""", RegexOption.MULTILINE)

    /**
     * Everything the watchdog decides on, in one map. Never throws.
     *
     * `available` is false when the state cannot be read at all (no DUMP
     * grant, Play services not installed); `connected` is null when the dump
     * came back but said nothing recognisable, which the watchdog treats as
     * "do not act".
     */
    fun status(context: Context): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>(
            "checked_at" to System.currentTimeMillis(),
            "device_owner" to AdminActions.isDeviceOwner(context),
            "network_validated" to networkValidated(context),
            "screen_on" to (context.getSystemService(PowerManager::class.java)?.isInteractive == true),
        )
        if (!installed(context)) {
            out["available"] = false
            out["reason"] = "Google Play services is not installed on this phone."
            return out
        }
        if (context.checkSelfPermission(Manifest.permission.DUMP) != PackageManager.PERMISSION_GRANTED) {
            out["available"] = false
            out["reason"] = "Exa does not hold DUMP. Run the provisioning script, or " +
                "grant it over adb: pm grant ${context.packageName} android.permission.DUMP"
            return out
        }
        val dump = try {
            runDumpsys("activity", "service", "GcmService")
        } catch (e: Exception) {
            out["available"] = false
            out["reason"] = "dumpsys failed: ${e.message ?: e::class.java.simpleName}"
            return out
        }
        if (dump.contains("Permission Denial")) {
            // The system's own wording names the missing permission; keep it
            // verbatim so the settings tile shows exactly what to grant.
            val denial = dump.lineSequence().firstOrNull { it.contains("Permission Denial") }?.trim()
            out["available"] = false
            out["reason"] = "The phone refused the dump: ${denial ?: "DUMP is not effective for Exa."}"
            Log.w(TAG, "dump refused: $denial")
            return out
        }
        out["available"] = true
        val connected = clientConnected.find(dump)?.groupValues?.get(1)
        out["connected"] = when {
            connected != null -> connected == "true"
            // Play services' process is not even running: the socket cannot
            // be up. (It restarts on demand, so this is a real dead state.)
            dump.contains("No services match") -> false
            else -> null
        }
        if (out["connected"] == null) {
            Log.w(TAG, "dump said nothing recognisable; first lines: " +
                dump.lineSequence().take(3).joinToString(" | ") { it.trim() })
        }
        out["connects"] = connects.find(dump)?.groupValues?.get(1)?.toIntOrNull()
        out["endpoint"] = endpoint.find(dump)?.groupValues?.get(1)
        val active = activeNetwork.find(dump)?.groupValues?.get(1)?.trim()
        out["active_network"] = active
        // Play services binds its socket to whatever it calls its active
        // network. When that is a split-tunnel VPN (Tailscale on the S8+:
        // routes for 100.x only, no default route) every connect fails in
        // ~40 ms with err:3, and a fresh process picks the same VPN again -
        // so this is the one dead state a restart cannot fix.
        val viaVpn = active?.contains("VPN(") == true
        out["via_vpn"] = viaVpn
        if (viaVpn) out["vpn_app"] = vpnAppLabel(context)
        // Play services' own recent connection log, so a diagnostic written
        // during an outage carries its side of the story.
        out["recent"] = dump.lineSequence()
            .filter { logLine.containsMatchIn(it) }
            .map { it.trim() }
            .toList()
            .takeLast(8)
        // One line per check, so `adb logcat -s ExaPushHealth` shows the
        // watchdog's view of the socket without opening the app.
        Log.i(
            TAG,
            "push connected=${out["connected"]} network=${out["network_validated"]} " +
                "connects=${out["connects"]} active=${out["active_network"]}",
        )
        return out
    }

    /**
     * Restarts Play services by hiding and unhiding it (Device Owner only).
     * Reports what happened; the unhide is verified and retried because a
     * hidden Play services is the worse outcome.
     */
    fun restartPlayServices(context: Context): Map<String, Any?> {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
            ?: return mapOf("ok" to false, "error" to "No device policy service.")
        if (!AdminActions.isDeviceOwner(context)) {
            return mapOf("ok" to false, "error" to "Exa is not the device owner, so it cannot restart Play services.")
        }
        if (!installed(context)) {
            return mapOf("ok" to false, "error" to "Google Play services is not installed on this phone.")
        }
        val admin = AdminActions.adminComponent(context)
        try {
            if (!dpm.isApplicationHidden(admin, PLAY_SERVICES)) {
                if (!dpm.setApplicationHidden(admin, PLAY_SERVICES, true)) {
                    return mapOf("ok" to false, "error" to "The phone refused to stop Play services.")
                }
                Thread.sleep(HIDE_HOLD_MS)
            }
        } catch (e: Exception) {
            Log.w(TAG, "hide failed: ${e.message}")
            return mapOf("ok" to false, "error" to (e.message ?: e::class.java.simpleName))
        } finally {
            // Always leave Play services visible, whatever happened above.
            unhide(dpm, admin)
        }
        val visible = try {
            !dpm.isApplicationHidden(admin, PLAY_SERVICES)
        } catch (e: Exception) {
            false
        }
        if (!visible) {
            Log.e(TAG, "Play services is still hidden after restart")
            return mapOf(
                "ok" to false,
                "error" to "Play services was stopped but could not be re-enabled. Reboot the phone.",
            )
        }
        Log.i(TAG, "Play services restarted")
        return mapOf("ok" to true)
    }

    /** Reboots the phone (Device Owner only). Android refuses during a call. */
    fun reboot(context: Context): Map<String, Any?> {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
            ?: return mapOf("ok" to false, "error" to "No device policy service.")
        if (!AdminActions.isDeviceOwner(context)) {
            return mapOf("ok" to false, "error" to "Exa is not the device owner, so it cannot reboot the phone.")
        }
        return try {
            Log.w(TAG, "Rebooting the phone at the push watchdog's request")
            dpm.reboot(AdminActions.adminComponent(context))
            mapOf("ok" to true)
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to (e.message ?: e::class.java.simpleName))
        }
    }

    // --- helpers ---------------------------------------------------------

    private fun unhide(dpm: DevicePolicyManager, admin: ComponentName) {
        repeat(3) { attempt ->
            try {
                if (!dpm.isApplicationHidden(admin, PLAY_SERVICES)) return
                if (dpm.setApplicationHidden(admin, PLAY_SERVICES, false)) return
            } catch (e: Exception) {
                Log.w(TAG, "unhide attempt ${attempt + 1} failed: ${e.message}")
            }
            Thread.sleep(500)
        }
    }

    private fun installed(context: Context): Boolean = try {
        context.packageManager.getApplicationInfo(PLAY_SERVICES, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    /**
     * A third-party app cannot ask the system which app owns the VPN, so
     * this names the one Exa knows to look for; anything else is "a VPN".
     */
    private fun vpnAppLabel(context: Context): String? = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo("com.tailscale.ipn", 0)).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    private fun networkValidated(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    /** Runs `dumpsys` with a timeout; returns stdout and stderr as text. */
    private fun runDumpsys(vararg args: String): String {
        val process = ProcessBuilder(listOf("dumpsys") + args)
            .redirectErrorStream(true)
            .start()
        val output = StringBuilder()
        val reader = Thread {
            process.inputStream.bufferedReader().use { r ->
                r.forEachLine { line ->
                    if (output.length < 200_000) output.append(line).append('\n')
                }
            }
        }
        reader.start()
        if (!process.waitFor(DUMP_TIMEOUT_S, TimeUnit.SECONDS)) {
            process.destroy()
            throw IllegalStateException("dumpsys timed out")
        }
        reader.join(2000)
        return output.toString()
    }
}

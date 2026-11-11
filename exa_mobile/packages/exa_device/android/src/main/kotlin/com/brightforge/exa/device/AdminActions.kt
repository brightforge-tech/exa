package com.brightforge.exa.device

import android.Manifest
import android.app.AlarmManager
import android.app.AppOpsManager
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.app.role.RoleManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.PermissionInfo
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * Exa's administrative standing on this phone, and the handful of things it
 * can fix about it by itself.
 *
 * On stock Android the privilege stack is: Device Owner (set once with
 * `dpm set-device-owner`), a few one-time `pm grant` / `appops` grants made
 * over adb, and special-access switches (notification listener,
 * accessibility) that Exa can flip for itself once it holds
 * WRITE_SECURE_SETTINGS. [status] reports every one of those as a plain
 * boolean so the settings screen can say exactly what is missing and the
 * Dart side can derive what Exa is able to do right now.
 *
 * Everything here reports rather than throws: a missing grant is an answer,
 * not an error.
 */
object AdminActions {
    private const val TAG = "ExaDevice"

    /** Hidden in the SDK, but [RoleManager.isRoleHeld] accepts the name. */
    private const val ROLE_ASSISTANT = "android.app.role.ASSISTANT"

    fun adminComponent(context: Context): ComponentName =
        ComponentName(context, ExaDeviceAdminReceiver::class.java)

    private fun dpm(context: Context): DevicePolicyManager? =
        context.getSystemService(DevicePolicyManager::class.java)

    fun isDeviceOwner(context: Context): Boolean =
        dpm(context)?.isDeviceOwnerApp(context.packageName) == true

    fun isAdminActive(context: Context): Boolean =
        dpm(context)?.isAdminActive(adminComponent(context)) == true

    /**
     * Everything the settings screen and the capabilities probe need, in one
     * map. [listenerClass] / [accessibilityClass] are the fully qualified
     * class names of the app's notification listener and accessibility
     * service - this module cannot name the app's classes, so the caller
     * does.
     */
    fun status(context: Context, listenerClass: String?, accessibilityClass: String?): Map<String, Any?> {
        val pkg = context.packageName
        val owner = isDeviceOwner(context)
        val admin = isAdminActive(context)
        val grants = linkedMapOf(
            "device_owner" to owner,
            "device_admin" to admin,
            "write_secure_settings" to granted(context, Manifest.permission.WRITE_SECURE_SETTINGS),
            "read_logs" to granted(context, Manifest.permission.READ_LOGS),
            "dump" to granted(context, Manifest.permission.DUMP),
            "usage_stats" to appOpAllowed(context, AppOpsManager.OPSTR_GET_USAGE_STATS),
            "overlay" to Settings.canDrawOverlays(context),
            "exact_alarm" to canScheduleExactAlarms(context),
            "battery_unrestricted" to isIgnoringBatteryOptimizations(context),
            "notification_listener" to (
                listenerClass != null &&
                    secureListContains(context, "enabled_notification_listeners", ComponentName(pkg, listenerClass))
                ),
            "notification_policy" to (
                context.getSystemService(NotificationManager::class.java)
                    ?.isNotificationPolicyAccessGranted == true
                ),
            "accessibility" to (
                accessibilityClass != null &&
                    secureListContains(context, "enabled_accessibility_services", ComponentName(pkg, accessibilityClass))
                ),
            "assistant_role" to roleHeld(context, ROLE_ASSISTANT),
            "call_screening_role" to roleHeld(context, "android.app.role.CALL_SCREENING"),
        )
        val runtime = linkedMapOf<String, Boolean>()
        for (permission in requestedDangerousPermissions(context)) {
            runtime[permission] = granted(context, permission)
        }
        return mapOf(
            "backend" to when {
                owner -> "device_owner"
                admin -> "device_admin"
                else -> "none"
            },
            "device_owner" to owner,
            "admin_active" to admin,
            "sdk" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "grants" to grants,
            "runtime" to runtime,
        )
    }

    /**
     * Grants Exa every dangerous (runtime) permission its own manifest asks
     * for, through the Device Owner policy API - no prompts. Returns each
     * permission with whether the grant took, so a refusal (or a permission
     * Android reserves for the user) is visible rather than assumed.
     */
    fun grantSelfRuntime(context: Context): Map<String, Any?> {
        val manager = dpm(context)
        if (manager == null || !isDeviceOwner(context)) {
            return mapOf(
                "ok" to false,
                "error" to "Exa is not the device owner on this phone.",
                "granted" to emptyMap<String, Boolean>(),
            )
        }
        val admin = adminComponent(context)
        val pkg = context.packageName
        val outcome = linkedMapOf<String, Boolean>()
        var all = true
        for (permission in requestedDangerousPermissions(context)) {
            val ok = try {
                manager.setPermissionGrantState(
                    admin, pkg, permission, DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED,
                ) && granted(context, permission)
            } catch (e: Exception) {
                Log.w(TAG, "grant $permission failed: ${e.message}")
                false
            }
            outcome[permission] = ok
            if (!ok) all = false
        }
        return mapOf("ok" to all, "granted" to outcome)
    }

    /** Adds Exa's notification listener to the enabled list. */
    fun enableNotificationListener(context: Context, component: String): Map<String, Any?> =
        enableSecureComponent(context, "enabled_notification_listeners", component)

    /** Adds Exa's accessibility service to the enabled list and switches accessibility on. */
    fun enableAccessibility(context: Context, component: String): Map<String, Any?> {
        val added = enableSecureComponent(context, "enabled_accessibility_services", component)
        if (added["ok"] != true) return added
        return try {
            Settings.Secure.putInt(context.contentResolver, "accessibility_enabled", 1)
            mapOf("ok" to true)
        } catch (e: SecurityException) {
            mapOf("ok" to false, "error" to secureSettingsError())
        }
    }

    /**
     * Opens the one system page that can fix a grant Exa cannot flip itself.
     * Falls back to Exa's own app-details page when a device lacks the
     * specific screen (Samsung moves a few).
     */
    fun openSettings(context: Context, screen: String): Map<String, Any?> {
        val pkg = context.packageName
        val packageUri = Uri.parse("package:$pkg")
        val intent = when (screen) {
            "assistant" -> Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
            "default_apps" -> Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            "notification_policy" -> Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
            "notification_listener" -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            "accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri)
            "usage_access" -> Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            "exact_alarm" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
            }
            "app_details" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
            "device_admin" -> Intent("android.settings.DEVICE_ADMIN_SETTINGS")
            else -> return mapOf("ok" to false, "error" to "Unknown settings screen '$screen'.")
        }
        return launch(context, intent, fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
    }

    /** The system "let this app ignore battery optimisations?" dialog. */
    fun requestBatteryExemption(context: Context): Map<String, Any?> {
        if (isIgnoringBatteryOptimizations(context)) return mapOf("ok" to true, "already" to true)
        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"),
        )
        return launch(context, intent, fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    /**
     * Gives up device ownership. Nothing else is undone: the app, its data
     * and the adb grants stay; only the Device Owner powers go. Reversible
     * with the provisioning script, minus the account dance if none were
     * added since.
     */
    fun clearDeviceOwner(context: Context): Map<String, Any?> {
        val manager = dpm(context) ?: return mapOf("ok" to false, "error" to "No device policy service.")
        if (!isDeviceOwner(context)) return mapOf("ok" to true, "already" to true)
        return try {
            @Suppress("DEPRECATION")
            manager.clearDeviceOwnerApp(context.packageName)
            mapOf("ok" to !isDeviceOwner(context))
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to (e.message ?: e::class.java.simpleName))
        }
    }

    // --- helpers ---------------------------------------------------------

    private fun granted(context: Context, permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun appOpAllowed(context: Context, op: String): Boolean {
        val appOps = context.getSystemService(AppOpsManager::class.java) ?: return false
        val uid = android.os.Process.myUid()
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(op, uid, context.packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(op, uid, context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return context.getSystemService(AlarmManager::class.java)?.canScheduleExactAlarms() == true
    }

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java)
            ?.isIgnoringBatteryOptimizations(context.packageName) == true

    private fun roleHeld(context: Context, role: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val roles = context.getSystemService(RoleManager::class.java) ?: return false
        return try {
            roles.isRoleAvailable(role) && roles.isRoleHeld(role)
        } catch (e: Exception) {
            false
        }
    }

    /** Both `pkg/.Short` and `pkg/full.Class` spellings count as the same component. */
    private fun secureListContains(context: Context, setting: String, component: ComponentName): Boolean {
        val raw = Settings.Secure.getString(context.contentResolver, setting) ?: return false
        return raw.split(':').any { entry ->
            ComponentName.unflattenFromString(entry.trim()) == component
        }
    }

    private fun enableSecureComponent(context: Context, setting: String, component: String): Map<String, Any?> {
        val target = ComponentName.unflattenFromString(component)
            ?: return mapOf("ok" to false, "error" to "'$component' is not a component name.")
        if (secureListContains(context, setting, target)) return mapOf("ok" to true, "already" to true)
        return try {
            val resolver = context.contentResolver
            val current = Settings.Secure.getString(resolver, setting).orEmpty()
            val entries = current.split(':').map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
            entries.add(target.flattenToString())
            Settings.Secure.putString(resolver, setting, entries.joinToString(":"))
            mapOf("ok" to secureListContains(context, setting, target))
        } catch (e: SecurityException) {
            mapOf("ok" to false, "error" to secureSettingsError())
        }
    }

    private fun secureSettingsError(): String =
        "Exa does not hold WRITE_SECURE_SETTINGS yet. Run the provisioning " +
            "script (tools/provision_device.ps1) or grant it over adb."

    /** The dangerous permissions this package's own manifest requests. */
    private fun requestedDangerousPermissions(context: Context): List<String> {
        val pm = context.packageManager
        val info = try {
            pm.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        } catch (e: PackageManager.NameNotFoundException) {
            return emptyList()
        }
        val requested = info.requestedPermissions ?: return emptyList()
        return requested.filter { permission ->
            try {
                val details = pm.getPermissionInfo(permission, 0)
                val base = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    details.protection
                } else {
                    @Suppress("DEPRECATION")
                    details.protectionLevel and PermissionInfo.PROTECTION_MASK_BASE
                }
                base == PermissionInfo.PROTECTION_DANGEROUS
            } catch (e: PackageManager.NameNotFoundException) {
                false
            }
        }
    }

    private fun launch(context: Context, intent: Intent, fallback: Intent): Map<String, Any?> {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: ActivityNotFoundException) {
            try {
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(fallback)
                mapOf("ok" to true, "fallback" to true)
            } catch (e2: ActivityNotFoundException) {
                mapOf("ok" to false, "error" to "This phone has no settings page for that.")
            }
        }
    }
}

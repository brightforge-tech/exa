package com.brightforge.exa.phone

import android.Manifest
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.telecom.TelecomManager
import android.telephony.PhoneNumberUtils
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Log
import java.util.Locale

/**
 * The phone things Exa can do, each reporting exactly what happened.
 *
 * Three honesty rules shape the result vocabulary:
 *  - `sent` means the SMS was handed to the phone's radio; `placed` means
 *    the call was started. Those are the only two words for "done".
 *  - `dialer_opened` / `composer_opened` mean the user still has to tap:
 *    WhatsApp has no API for a personal account to send without the user
 *    pressing Send, so the best Exa can do is open the chat with the words
 *    typed in. A tool must relay that, never round it up to "sent".
 *  - `notified` means nobody was looking at the phone, so a one-tap
 *    notification was posted instead - what a scheduled job does when it
 *    cannot (WhatsApp) or should not (a call while the phone is in a pocket)
 *    act directly.
 */
object PhoneActions {
    private const val TAG = "ExaPhone"

    /** Notifications that carry a pending call or message to send. */
    const val CHANNEL_ID = "exa_phone_actions"

    private const val WHATSAPP = "com.whatsapp"
    private const val WHATSAPP_BUSINESS = "com.whatsapp.w4b"

    fun permissions(context: Context): Map<String, Boolean> = mapOf(
        "sms" to granted(context, Manifest.permission.SEND_SMS),
        "call" to granted(context, Manifest.permission.CALL_PHONE),
        "contacts" to granted(context, Manifest.permission.READ_CONTACTS),
        "telephony" to hasTelephony(context),
    )

    /**
     * Whether anyone is plausibly looking at the phone. A scheduled call
     * dials straight away only when the screen is on and unlocked; otherwise
     * the job posts a tap-to-call notification, because a phone that starts
     * ringing someone from inside a bag is not a feature.
     */
    fun deviceState(context: Context): Map<String, Any> {
        val power = context.getSystemService(PowerManager::class.java)
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        return mapOf(
            "interactive" to (power?.isInteractive ?: true),
            "locked" to (keyguard?.isKeyguardLocked ?: false),
        )
    }

    /** E.164 when the number can be read that way, else the bare digits. */
    fun normalize(context: Context, raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val e164 = PhoneNumberUtils.formatNumberToE164(trimmed, countryIso(context))
        if (!e164.isNullOrBlank()) return e164
        return PhoneNumberUtils.normalizeNumber(trimmed).takeIf { it.isNotBlank() }
    }

    private fun countryIso(context: Context): String {
        val telephony = context.getSystemService(TelephonyManager::class.java)
        val iso = telephony?.simCountryIso?.takeIf { it.isNotBlank() }
            ?: telephony?.networkCountryIso?.takeIf { it.isNotBlank() }
            ?: Locale.getDefault().country
        return iso.uppercase(Locale.ROOT)
    }

    /**
     * Contacts whose display name contains [query], each with every distinct
     * phone number on the card. Numbers come back normalized so the caller
     * can tell "07700 900123" and "+44 7700 900123" are the same entry.
     */
    fun findContacts(context: Context, query: String, limit: Int): List<Map<String, Any?>> {
        if (!granted(context, Manifest.permission.READ_CONTACTS)) {
            throw SecurityException("Exa does not have permission to read contacts")
        }
        val needle = query.trim()
        val projection = arrayOf(
            Phone.CONTACT_ID,
            Phone.DISPLAY_NAME_PRIMARY,
            Phone.NUMBER,
            Phone.NORMALIZED_NUMBER,
            Phone.TYPE,
            Phone.LABEL,
            Phone.IS_SUPER_PRIMARY,
        )
        val selection = if (needle.isEmpty()) null else "${Phone.DISPLAY_NAME_PRIMARY} LIKE ?"
        val args = if (needle.isEmpty()) null else arrayOf("%$needle%")
        val contacts = LinkedHashMap<Long, MutableMap<String, Any?>>()
        context.contentResolver.query(
            Phone.CONTENT_URI,
            projection,
            selection,
            args,
            "${Phone.DISPLAY_NAME_PRIMARY} COLLATE NOCASE ASC",
        )?.use { cursor ->
            val idIx = cursor.getColumnIndexOrThrow(Phone.CONTACT_ID)
            val nameIx = cursor.getColumnIndexOrThrow(Phone.DISPLAY_NAME_PRIMARY)
            val numberIx = cursor.getColumnIndexOrThrow(Phone.NUMBER)
            val normalizedIx = cursor.getColumnIndexOrThrow(Phone.NORMALIZED_NUMBER)
            val typeIx = cursor.getColumnIndexOrThrow(Phone.TYPE)
            val labelIx = cursor.getColumnIndexOrThrow(Phone.LABEL)
            val primaryIx = cursor.getColumnIndexOrThrow(Phone.IS_SUPER_PRIMARY)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIx)
                // Rows are sorted by name, so once the cap is reached and a
                // new contact begins, nothing further can be needed.
                if (!contacts.containsKey(id) && contacts.size >= limit) break
                val name = cursor.getString(nameIx)?.trim()?.takeIf { it.isNotEmpty() } ?: continue
                val number = cursor.getString(numberIx)?.trim()?.takeIf { it.isNotEmpty() } ?: continue
                val normalized = cursor.getString(normalizedIx)?.takeIf { it.isNotBlank() }
                    ?: normalize(context, number)
                    ?: number
                val typeLabel = Phone.getTypeLabel(
                    context.resources, cursor.getInt(typeIx), cursor.getString(labelIx),
                ).toString()
                val entry = contacts.getOrPut(id) {
                    mutableMapOf("name" to name, "numbers" to mutableListOf<Map<String, Any?>>())
                }
                @Suppress("UNCHECKED_CAST")
                val numbers = entry["numbers"] as MutableList<Map<String, Any?>>
                if (numbers.none { it["normalized"] == normalized }) {
                    numbers.add(
                        mapOf(
                            "number" to number,
                            "normalized" to normalized,
                            "label" to typeLabel,
                            "primary" to (cursor.getInt(primaryIx) != 0),
                        ),
                    )
                }
            }
        }
        return contacts.values.toList()
    }

    fun sendSms(context: Context, number: String, text: String): Map<String, Any?> {
        if (!granted(context, Manifest.permission.SEND_SMS)) {
            return failed(
                "Exa does not have permission to send text messages. The user can " +
                    "grant it in Settings > Phone access.",
            )
        }
        if (!hasTelephony(context)) return failed("This device cannot send text messages.")
        if (text.isBlank()) return failed("The message is empty.")
        val target = normalize(context, number) ?: return failed("'$number' is not a phone number.")
        return try {
            val manager = if (Build.VERSION.SDK_INT >= 31) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            } ?: return failed("The SMS service is not available on this device.")
            val parts = manager.divideMessage(text)
            if (parts.size > 1) {
                manager.sendMultipartTextMessage(target, null, parts, null, null)
            } else {
                manager.sendTextMessage(target, null, text, null, null)
            }
            mapOf("status" to "sent", "number" to target, "parts" to parts.size)
        } catch (e: Exception) {
            Log.w(TAG, "sendSms failed", e)
            failed("The text could not be sent: ${e.message ?: e::class.java.simpleName}")
        }
    }

    /**
     * Dials [number]. With CALL_PHONE the call is started outright (through
     * Telecom, which works from a background context; `ACTION_CALL` as the
     * fallback); without it the dialler opens with the number typed in, and
     * the result says so.
     */
    fun placeCall(context: Context, number: String): Map<String, Any?> {
        if (!hasTelephony(context)) return failed("This device cannot place calls.")
        val target = normalize(context, number) ?: return failed("'$number' is not a phone number.")
        val uri = Uri.fromParts("tel", target, null)
        if (granted(context, Manifest.permission.CALL_PHONE)) {
            try {
                val telecom = context.getSystemService(TelecomManager::class.java)
                if (telecom != null) {
                    telecom.placeCall(uri, Bundle())
                    return mapOf("status" to "placed", "number" to target)
                }
            } catch (e: Exception) {
                Log.w(TAG, "placeCall via Telecom failed, trying ACTION_CALL", e)
            }
            try {
                context.startActivity(
                    Intent(Intent.ACTION_CALL, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return mapOf("status" to "placed", "number" to target)
            } catch (e: Exception) {
                Log.w(TAG, "ACTION_CALL failed, falling back to the dialler", e)
            }
        }
        return try {
            context.startActivity(
                Intent(Intent.ACTION_DIAL, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            mapOf("status" to "dialer_opened", "number" to target)
        } catch (e: Exception) {
            failed("Could not open the dialler: ${e.message ?: e::class.java.simpleName}")
        }
    }

    /**
     * Opens WhatsApp on the chat for [number] with [text] typed into the
     * composer. The user presses Send - there is no way around that for a
     * personal account, and the result says `composer_opened`, never `sent`.
     * A null [number] opens WhatsApp's chat picker with the text ready.
     */
    fun openWhatsApp(
        context: Context,
        number: String?,
        text: String,
        business: Boolean,
    ): Map<String, Any?> {
        val pkg = if (business) WHATSAPP_BUSINESS else WHATSAPP
        if (!isInstalled(context, pkg)) {
            return failed(
                if (business) "WhatsApp Business is not installed on this phone."
                else "WhatsApp is not installed on this phone.",
            )
        }
        val intent = whatsAppIntent(context, pkg, number, text)
        return try {
            context.startActivity(intent)
            mapOf(
                "status" to "composer_opened",
                "number" to intent.getStringExtra(EXTRA_DIGITS),
            )
        } catch (e: ActivityNotFoundException) {
            failed("WhatsApp could not be opened.")
        } catch (e: Exception) {
            failed("WhatsApp could not be opened: ${e.message ?: e::class.java.simpleName}")
        }
    }

    private const val EXTRA_DIGITS = "exa_digits"

    private fun whatsAppIntent(
        context: Context,
        pkg: String,
        number: String?,
        text: String,
    ): Intent {
        // wa.me wants the international number as bare digits, no '+'.
        val digits = number
            ?.let { normalize(context, it) ?: it }
            ?.filter { it.isDigit() }
            ?.takeIf { it.isNotEmpty() }
        val uri = Uri.parse("https://wa.me/${digits ?: ""}").buildUpon()
            .appendQueryParameter("text", text)
            .build()
        return Intent(Intent.ACTION_VIEW, uri)
            .setPackage(pkg)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_DIGITS, digits)
    }

    fun isInstalled(context: Context, pkg: String): Boolean {
        if (pkg.isBlank()) return false
        return try {
            context.packageManager.getPackageInfo(pkg, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * Posts a notification whose tap performs the action - the form a
     * scheduled job's call or WhatsApp message takes when the user is not
     * there to tap Send (or should not be called for from a pocket).
     */
    fun notifyAction(
        context: Context,
        kind: String,
        number: String?,
        text: String,
        title: String,
        body: String,
    ): Map<String, Any?> {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return failed("Notifications are not available.")
        if (!manager.areNotificationsEnabled()) {
            return failed("Notifications are turned off for Exa, so there is no way to hand this to the user.")
        }
        val intent: Intent = when (kind) {
            "call" -> {
                val target = number?.let { normalize(context, it) ?: it }
                    ?: return failed("No number to call.")
                val uri = Uri.fromParts("tel", target, null)
                val action = if (granted(context, Manifest.permission.CALL_PHONE)) {
                    Intent.ACTION_CALL
                } else {
                    Intent.ACTION_DIAL
                }
                Intent(action, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            "whatsapp" -> {
                if (!isInstalled(context, WHATSAPP)) return failed("WhatsApp is not installed on this phone.")
                whatsAppIntent(context, WHATSAPP, number, text)
            }
            else -> return failed("Unknown phone action '$kind'.")
        }
        ensureChannel(manager)
        val requestCode = (System.currentTimeMillis() and 0x7fffff).toInt()
        val pending = PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(context.applicationInfo.icon)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .build()
        manager.notify(requestCode, notification)
        return mapOf("status" to "notified")
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Calls and messages to send",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "A scheduled call or message that needs one tap from you"
            },
        )
    }

    private fun hasTelephony(context: Context) =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)

    private fun granted(context: Context, permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun failed(reason: String): Map<String, Any?> =
        mapOf("status" to "failed", "error" to reason)
}

# Provisioning the Galaxy S25 for Exa v3

Exa v3 manages the phone as its **Device Owner**. On a stock Samsung this is
the highest standing an app can have without a custom OS, and One UI 8 has
closed the custom-OS route (no bootloader unlock), so this is the path.

Nothing in this procedure wipes the phone. Apps, data, Exa's own database and
API keys all stay. What it does need is a short window with **no accounts on
the phone**, because Android refuses to set a device owner while any account
exists.

## What you get

- Exa can install, remove, hide and suspend apps, grant itself permissions,
  lock and reboot the phone, and change system settings.
- With the one-time adb grants, Exa can switch on its own notification access
  and screen reading, read system logs, and stay out of battery restrictions.
- Play Integrity is unaffected: the bootloader stays locked and the OS is
  stock, so Wallet, banking apps and Samsung Pay keep working.

## What you give up while Exa is device owner

- **Secure Folder** cannot be used (it needs a second user, which a managed
  device does not allow). Move anything out of it first.
- **Samsung Cloud backup** and **Smart Switch backup** may refuse a managed
  device. Take a backup *before* provisioning.
- The lock screen and Settings show a "this device is managed" notice.
  Cosmetic.
- Exa cannot be uninstalled from the launcher. Removing device owner from
  Exa's own settings restores that.

## Before you start

1. Back up the phone (Smart Switch to a PC, or Samsung Cloud).
2. Install the v3 build in place. Never `flutter install`; it uninstalls first
   and deletes Exa's data.
   ```
   adb -s <serial> install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
   ```
3. **Secure Folder**: move files out, then Settings > Security and privacy >
   Secure Folder > More > Uninstall.
4. **Dual Messenger**: Settings > Advanced features > Dual Messenger, switch
   every app off.
5. Check only the primary user remains:
   ```
   adb -s <serial> shell pm list users
   ```
   Expect a single `UserInfo{0:...}` line.
6. **Remove every account.** Settings > Accounts and backup > Manage accounts.
   Google, Samsung, WhatsApp, Signal, Telegram, Microsoft, Exa's own mail
   accounts if they registered one. List what is left with:
   ```
   adb -s <serial> shell dumpsys account | findstr "Account {"
   ```
   The script refuses to continue while any remain and prints them.

## Run the script

```
powershell -ExecutionPolicy Bypass -File tools\provision_device.ps1
```
(or `tools/provision_device.sh` from Git Bash.) Add `-DryRun` to see the
commands first, `-Check` to only report.

It sets the device owner, then grants (once, over adb):

| Grant | Why |
|---|---|
| `WRITE_SECURE_SETTINGS` | Exa flips its own notification access and screen reading, and changes system settings |
| `READ_LOGS`, `DUMP` | "Why did that fail?" answered from the phone's own logs and service state |
| `GET_USAGE_STATS` app op | App usage |
| `SYSTEM_ALERT_WINDOW` app op | The floating bubble, with no settings bounce |
| `SCHEDULE_EXACT_ALARM` app op | Exact-time reminders and briefs |
| Doze allowlist | Background work is not frozen |
| DND access, notification access | Do Not Disturb control; notifications from every app |

Every grant survives reboots and in-place `adb install -r` updates. Only
uninstalling Exa loses them, and then this script is the fix (minus the
account dance if Exa is still the device owner).

## After the script

1. Add your accounts back. WhatsApp and similar apps re-create theirs when
   opened.
2. Settings > Apps > Default apps > Digital assistant app > **Exa**. Bixby or
   Gemini may hold it now.
3. Settings > Apps > Exa > Battery > **Unrestricted**. Then Settings >
   Battery > Background usage limits: make sure Exa is not in Sleeping apps
   or Deep sleeping apps. Samsung re-adds apps here on its own; Exa's
   Background reliability screen checks it.
4. Open Exa > Settings > **Device control**. Everything should be green;
   press **Grant all** for Exa's runtime permissions and **Enable** on
   anything still off.
5. Leave the **Push watchdog** on the same screen switched on. Play
   services on this phone stops reconnecting its push socket after a Wi-Fi
   blip or a deep-Doze entry, and every FCM app (Teams, Outlook, Gmail) goes
   quiet until it is restarted; the watchdog does that by itself. Reading
   the state needs the DUMP and PACKAGE_USAGE_STATS grants the script
   makes (the activity-manager dump checks both); the restart needs Device
   Owner. If the tile says the phone refused the dump, it quotes the
   permission the system named. If it says push is blocked by the VPN,
   restarting will not help: a split-tunnel VPN (Tailscale without an
   exit node) has no route to Google and Play services binds to it anyway.
   Exclude Google Play services from the VPN in the VPN app, or use an
   exit node.

## Undo

Exa > Settings > Device control > **Remove device owner** (type REMOVE).
Exa keeps running with its data; only the device powers go. The adb grants
stay until Exa is uninstalled.

## Troubleshooting

- `Not allowed to set the device owner because there are already some
  accounts on the device`: an account is still registered. The script
  prints them; some only show under Manage accounts after scrolling.
- `Not allowed to set the device owner because there are already several
  users on the device`: Secure Folder or Dual Messenger is still installed.
- `Unknown admin: ComponentInfo{...}`: the installed build predates the
  device plugin. Reinstall the v3 APK in place.
- The lock screen says the device is managed by an organisation: expected.
- Something stopped working after a reinstall: a full uninstall drops every
  grant. Run the script again.

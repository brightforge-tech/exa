<#
.SYNOPSIS
  Makes Exa the Device Owner of the phone and applies the one-time adb grants.
  Nothing is wiped: apps, data and Exa's own database stay exactly as they are.

.DESCRIPTION
  Run from the repo with the phone plugged in and USB debugging on:

    powershell -ExecutionPolicy Bypass -File tools\provision_device.ps1

  What it does, in order:
    1. Checks the phone is connected and Exa is installed.
    2. If Exa is not yet the device owner: checks there are no extra users
       (Secure Folder, Dual Messenger) and no accounts, then runs
       `dpm set-device-owner`. Stops with instructions if either check fails.
    3. Applies the grants only adb can make. Each survives reboots and
       in-place `adb install -r` updates; only uninstalling Exa loses them.
    4. Verifies everything and lists the hand steps that remain.

  Re-running is safe at any time; -Check only reports.

.PARAMETER Serial   adb serial of the phone (default: the only connected device).
.PARAMETER Package  Exa's package name.
.PARAMETER Check    Report the current state without changing anything.
.PARAMETER DryRun   Print the adb commands instead of running them.
#>
param(
    [string]$Serial = "",
    [string]$Package = "com.brightforge.exa",
    [switch]$Check,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $Serial) {
    $connected = @(& adb devices | Select-String -Pattern "^(\S+)\s+device$" | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($connected.Count -ne 1) {
        throw "Found $($connected.Count) connected devices. Connect exactly one phone or pass -Serial <serial> (see 'adb devices')."
    }
    $Serial = $connected[0]
}
$AdminComponent = "$Package/com.brightforge.exa.device.ExaDeviceAdminReceiver"
$ListenerComponent = "$Package/com.brightforge.exa.messaging.ExaNotificationListener"

function Invoke-Shell([string]$Command) {
    $lines = & adb -s $Serial shell $Command
    if ($null -eq $lines) { return "" }
    return ($lines -join "`n")
}

function Step([string]$Label, [string]$Command) {
    Write-Host "-> $Label" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "   adb -s $Serial shell $Command" -ForegroundColor DarkGray
        return ""
    }
    $out = Invoke-Shell $Command
    if ($out) {
        foreach ($line in ($out -split "`n")) { Write-Host "   $line" }
    }
    return $out
}

function Report([string]$Label, [bool]$Ok) {
    if ($Ok) {
        Write-Host "  [OK] $Label" -ForegroundColor Green
    } else {
        Write-Host "  [--] $Label" -ForegroundColor Yellow
    }
}

Write-Host "Exa device-owner provisioning  (serial $Serial, package $Package)"
Write-Host ""

# 1. Phone and app present.
$devices = & adb devices
$connected = $false
foreach ($line in $devices) {
    if ($line -match "^$([regex]::Escape($Serial))\s+device") { $connected = $true }
}
if (-not $connected) {
    throw "Phone $Serial is not connected, or USB debugging is not authorised (adb devices)."
}
$path = Invoke-Shell "pm path $Package"
if (-not $path) {
    throw "$Package is not installed. Install the v3 build first: adb -s $Serial install -r <apk>"
}

$owners = Invoke-Shell "dpm list-owners"
$isOwner = $owners -match [regex]::Escape($Package)

if (-not $Check) {
    if ($isOwner) {
        Write-Host "-> Exa is already the device owner" -ForegroundColor Green
    } else {
        # 2a. Only the primary user may exist.
        $users = Invoke-Shell "pm list users"
        $extra = @()
        foreach ($m in [regex]::Matches($users, 'UserInfo\{(\d+):')) {
            $id = [int]$m.Groups[1].Value
            if ($id -ne 0) { $extra += $id }
        }
        if ($extra.Count -gt 0) {
            Write-Host $users
            throw ("Other users or profiles exist (ids: $($extra -join ', ')). " +
                "Uninstall Secure Folder (user 150) and Dual Messenger (user 95) " +
                "first, then run this again.")
        }

        # 2b. No accounts of any kind.
        $accounts = Invoke-Shell "dumpsys account"
        $accountLines = @()
        foreach ($line in ($accounts -split "`n")) {
            if ($line -match 'Account \{') { $accountLines += $line.Trim() }
        }
        if ($accountLines.Count -gt 0) {
            Write-Host "Accounts still on the phone:" -ForegroundColor Yellow
            foreach ($a in $accountLines) { Write-Host "   $a" }
            throw ("Android refuses to set a device owner while any account exists. " +
                "Remove every account (Settings > Accounts and backup > Manage accounts; " +
                "WhatsApp, Signal and Samsung count too), run this again, then add them back.")
        }

        # 2c. Set the owner.
        $result = Step "Setting Exa as device owner" "dpm set-device-owner $AdminComponent"
        if (-not $DryRun -and ($result -notmatch 'Success')) {
            throw "set-device-owner failed: $result"
        }
    }

    # 3. Grants only adb can make.
    Step "Write secure settings" "pm grant $Package android.permission.WRITE_SECURE_SETTINGS" | Out-Null
    Step "Read system logs"      "pm grant $Package android.permission.READ_LOGS" | Out-Null
    Step "Read service state"    "pm grant $Package android.permission.DUMP" | Out-Null
    # Dumping the activity manager (the push watchdog reads Play services' push
    # state that way) needs this permission as well as the usage-access app-op.
    Step "Usage stats permission" "pm grant $Package android.permission.PACKAGE_USAGE_STATS" | Out-Null
    Step "Usage access"          "appops set $Package GET_USAGE_STATS allow" | Out-Null
    Step "Draw over other apps"  "appops set $Package SYSTEM_ALERT_WINDOW allow" | Out-Null
    Step "Exact alarms"          "appops set $Package SCHEDULE_EXACT_ALARM allow" | Out-Null
    Step "Doze allowlist"        "dumpsys deviceidle whitelist +$Package" | Out-Null
    Step "Do Not Disturb access" "cmd notification allow_dnd $Package" | Out-Null
    Step "Notification access"   "cmd notification allow_listener $ListenerComponent" | Out-Null
}

# 4. Verify.
Write-Host ""
Write-Host "Verification" -ForegroundColor Cyan
$owners = Invoke-Shell "dpm list-owners"
Report "Device owner" ($owners -match [regex]::Escape($Package))

$pkgDump = Invoke-Shell "dumpsys package $Package"
foreach ($perm in @('WRITE_SECURE_SETTINGS', 'READ_LOGS', 'DUMP')) {
    Report $perm ($pkgDump -match "android\.permission\.${perm}: granted=true")
}
foreach ($op in @('GET_USAGE_STATS', 'SYSTEM_ALERT_WINDOW', 'SCHEDULE_EXACT_ALARM')) {
    $mode = Invoke-Shell "appops get $Package $op"
    Report $op ($mode -match 'allow')
}
$idle = Invoke-Shell "dumpsys deviceidle whitelist"
Report "Doze allowlist" ($idle -match [regex]::Escape($Package))
$listeners = Invoke-Shell "settings get secure enabled_notification_listeners"
Report "Notification access" ($listeners -match 'ExaNotificationListener')

Write-Host ""
Write-Host "Still by hand (once):" -ForegroundColor Cyan
Write-Host "  - Add your accounts back (Settings > Accounts and backup > Manage accounts)."
Write-Host "  - Settings > Apps > Default apps > Digital assistant app > Exa."
Write-Host "  - Settings > Apps > Exa > Battery > Unrestricted, and keep Exa out of Sleeping apps."
Write-Host "  - Open Exa > Settings > Device control and press Grant all / Enable on anything left."

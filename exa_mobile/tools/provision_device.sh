#!/usr/bin/env bash
# Makes Exa the Device Owner of the phone and applies the one-time adb grants.
# Nothing is wiped. See provision_device.ps1 (the same steps) and
# docs/PROVISION_DEVICE.md for the hand steps around it.
#
#   tools/provision_device.sh [--serial <serial>] [--check] [--dry-run]

set -euo pipefail

SERIAL=""
PACKAGE="com.brightforge.exa"
CHECK=0
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --package) PACKAGE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SERIAL" ]]; then
  mapfile -t connected < <(adb devices | tr -d '\r' | awk '$2=="device"{print $1}')
  if [[ ${#connected[@]} -ne 1 ]]; then
    echo "Found ${#connected[@]} connected devices. Connect exactly one phone or pass --serial <serial> (see 'adb devices')." >&2
    exit 1
  fi
  SERIAL="${connected[0]}"
fi

ADMIN="$PACKAGE/com.brightforge.exa.device.ExaDeviceAdminReceiver"
LISTENER="$PACKAGE/com.brightforge.exa.messaging.ExaNotificationListener"

sh() { adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
step() {
  local label="$1"; shift
  echo "-> $label"
  if [[ $DRY -eq 1 ]]; then echo "   adb -s $SERIAL shell $*"; return 0; fi
  sh "$@" | sed 's/^/   /' || true
}
report() { if [[ "$2" == "1" ]]; then echo "  [OK] $1"; else echo "  [--] $1"; fi; }

echo "Exa device-owner provisioning  (serial $SERIAL, package $PACKAGE)"
echo

adb devices | grep -qE "^$SERIAL[[:space:]]+device" \
  || { echo "Phone $SERIAL is not connected or not authorised." >&2; exit 1; }
[[ -n "$(sh pm path "$PACKAGE")" ]] \
  || { echo "$PACKAGE is not installed. adb -s $SERIAL install -r <apk> first." >&2; exit 1; }

is_owner() { sh dpm list-owners | grep -q "$PACKAGE"; }

if [[ $CHECK -eq 0 ]]; then
  if is_owner; then
    echo "-> Exa is already the device owner"
  else
    users="$(sh pm list users)"
    extra="$(echo "$users" | grep -oE 'UserInfo\{[0-9]+:' | grep -oE '[0-9]+' | grep -v '^0$' || true)"
    if [[ -n "$extra" ]]; then
      echo "$users"
      echo "Other users or profiles exist (ids: $(echo "$extra" | tr '\n' ' ')). Uninstall Secure Folder (150) and Dual Messenger (95) first." >&2
      exit 1
    fi
    accounts="$(sh dumpsys account | grep 'Account {' || true)"
    if [[ -n "$accounts" ]]; then
      echo "Accounts still on the phone:"
      echo "$accounts" | sed 's/^/   /'
      echo "Remove every account (Settings > Accounts and backup > Manage accounts), run this again, then add them back." >&2
      exit 1
    fi
    out="$(step "Setting Exa as device owner" dpm set-device-owner "$ADMIN")"
    echo "$out"
    if [[ $DRY -eq 0 ]] && ! echo "$out" | grep -q Success; then
      echo "set-device-owner failed" >&2; exit 1
    fi
  fi

  step "Write secure settings" pm grant "$PACKAGE" android.permission.WRITE_SECURE_SETTINGS
  step "Read system logs"      pm grant "$PACKAGE" android.permission.READ_LOGS
  step "Read service state"    pm grant "$PACKAGE" android.permission.DUMP
  # The activity-manager dump behind the push watchdog needs this permission
  # as well as the usage-access app-op below.
  step "Usage stats permission" pm grant "$PACKAGE" android.permission.PACKAGE_USAGE_STATS
  step "Usage access"          appops set "$PACKAGE" GET_USAGE_STATS allow
  step "Draw over other apps"  appops set "$PACKAGE" SYSTEM_ALERT_WINDOW allow
  step "Exact alarms"          appops set "$PACKAGE" SCHEDULE_EXACT_ALARM allow
  step "Doze allowlist"        dumpsys deviceidle whitelist "+$PACKAGE"
  step "Do Not Disturb access" cmd notification allow_dnd "$PACKAGE"
  step "Notification access"   cmd notification allow_listener "$LISTENER"
fi

echo
echo "Verification"
if is_owner; then report "Device owner" 1; else report "Device owner" 0; fi
pkgdump="$(sh dumpsys package "$PACKAGE")"
for perm in WRITE_SECURE_SETTINGS READ_LOGS DUMP; do
  if echo "$pkgdump" | grep -q "android.permission.$perm: granted=true"; then report "$perm" 1; else report "$perm" 0; fi
done
for op in GET_USAGE_STATS SYSTEM_ALERT_WINDOW SCHEDULE_EXACT_ALARM; do
  if sh appops get "$PACKAGE" "$op" | grep -q allow; then report "$op" 1; else report "$op" 0; fi
done
if sh dumpsys deviceidle whitelist | grep -q "$PACKAGE"; then report "Doze allowlist" 1; else report "Doze allowlist" 0; fi
if sh settings get secure enabled_notification_listeners | grep -q ExaNotificationListener; then report "Notification access" 1; else report "Notification access" 0; fi

cat <<'EOF'

Still by hand (once):
  - Add your accounts back (Settings > Accounts and backup > Manage accounts).
  - Settings > Apps > Default apps > Digital assistant app > Exa.
  - Settings > Apps > Exa > Battery > Unrestricted, and keep Exa out of Sleeping apps.
  - Open Exa > Settings > Device control and press Grant all / Enable on anything left.
EOF

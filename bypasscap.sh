#!/system/bin/sh
# chargebypasscap-pmi - userspace charge cap for POCO X3 Pro (vayu).
# Direct sysfs control via the standard PMI node:
#   /sys/class/power_supply/battery/input_suspend (1 = suspend, 0 = resume)
# Verified on RE404 kernel: 1 pins battery at ~0 mA, 0 resumes full charging.
# No app needed; N0Kontzzz Kernel Manager writes the same node, so its
# bypass toggle remains usable as a manual backup (last writer wins).
# Behavior (always on while cable is plugged, cap adjustable in WebUI):
#   - Battery reaches CAP while charging -> writes 1. Phone runs off the
#     cable, battery rests at ~CAP.
#   - Battery falls to CAP-2 while suspended -> writes 0, charging resumes.
#   - You want 100% (travel day)? When it holds at CAP, use the action
#     button to release bypass once. The daemon backs off until you unplug.
#     Next plug session the cap is active again automatically.
#   - Plug in = intent to charge: on every fresh plug-in below CAP the
#     daemon makes sure bypass is OFF.
#   - Cap is set in the WebUI (Open button, slider 50-100%, default 80)
#     and stored in /data/adb/chargebypasscap-pmi/high. Daemon re-reads it
#     every poll, no reboot needed.
#
# Resume is always CAP-2: while holding the battery sits at ~0 mA so the
# resume level is almost never reached; the 2% gap just defeats ±1%
# fuel-gauge noise and keeps grab-and-go charge predictable.
#
# Requirements: root + a kernel that honors input_suspend (RE404 verified).
# Runs as root from the KernelSU module service.sh at boot.

MODDIR=/data/adb/chargebypasscap-pmi
LOG=$MODDIR/cap.log
HOLDING=$MODDIR/holding
OVERRIDE=$MODDIR/override
NODE=/sys/class/power_supply/battery/input_suspend
CAP=/sys/class/power_supply/battery/capacity
CUR=/sys/class/power_supply/battery/current_now
USBON=/sys/class/power_supply/usb/online
HIGH_FILE=$MODDIR/high
POLL=60
CHG_THRESH=-500000
GRACE_POLLS=2

# Adjustable cap: WebUI slider writes 50-100 into $HIGH_FILE.
# LOW (resume level) is always HIGH-2 to stop flapping.
read_high() {
  h=$(cat $HIGH_FILE 2>/dev/null)
  case "$h" in
    ''|*[!0-9]*) h=80 ;;
  esac
  [ "$h" -lt 50 ] && h=50
  [ "$h" -gt 100 ] && h=100
  echo "$h"
}

mkdir -p $MODDIR
rm -f $HOLDING $OVERRIDE

log() {
  echo "$(date '+%m-%d %H:%M') $1" >> $LOG
  tail -n 200 $LOG > $LOG.tmp
  mv $LOG.tmp $LOG
}

is_charging() { [ "$1" -lt "$CHG_THRESH" ]; }

SCRIPTDIR=$(dirname "$0")
MODPROP=$SCRIPTDIR/module.prop
LAST_STATUS=$MODDIR/last_status

update_desc() {
  # Rewrite whenever module.prop does not already carry this exact status,
  # so external overwrites (module updates, manager edits) self-heal
  # on the next poll instead of going blind.
  want="[$1] $2"
  cur=$(grep '^description=' $MODPROP 2>/dev/null | sed 's/^description=//')
  if [ "$cur" != "$want" ]; then
    if grep -q '^description=' $MODPROP 2>/dev/null; then
      sed -i "s|^description=.*|description=$want|" $MODPROP
    fi
    echo "$1" > $LAST_STATUS
  fi
}

prev_usb=$(cat $USBON 2>/dev/null)
cap0=$(cat $CAP 2>/dev/null)
cur0=$(cat $CUR 2>/dev/null)
rm -f $OVERRIDE
HIGH=$(read_high); LOW=$((HIGH - 2))
if [ "$prev_usb" = "1" ] && [ -n "$cap0" ] && [ "$cap0" -ge "$HIGH" ] && [ -n "$cur0" ] && ! is_charging "$cur0"; then
  touch $HOLDING
  log "bypasscap started (adopted existing hold at ${cap0}%, cap ${HIGH}%)"
else
  rm -f $HOLDING
  log "bypasscap started (always-on ${HIGH}% cap, override via action button)"
fi

grace=0

loop() {
  while true; do
    HIGH=$(read_high); LOW=$((HIGH - 2))
    BASE_DESC="${HIGH}% cap via input_suspend. Open=set cap, Action=full charge."
    usb=$(cat $USBON 2>/dev/null)
    cap=$(cat $CAP 2>/dev/null)
    cur=$(cat $CUR 2>/dev/null)

    # Fresh plug-in: intent to charge. Clear session state; reconcile below cap.
    if [ "$usb" = "1" ] && [ "$prev_usb" != "1" ]; then
      rm -f $HOLDING $OVERRIDE
      grace=0
      log "plug-in at $cap% (cap ${HIGH}%)"
      if [ -n "$cap" ] && [ "$cap" -lt "$HIGH" ] && [ -n "$cur" ] && ! is_charging "$cur"; then
        log "plug-in below $HIGH suspended -> bypass OFF"
        echo 0 > $NODE
        sleep 30
      fi
    fi
    prev_usb=$usb

    if [ "$usb" = "1" ] && [ -n "$cap" ] && [ -n "$cur" ]; then
      if [ "$grace" -gt 0 ]; then
        # Settling after our own node write: hands off.
        grace=$((grace - 1))
      elif [ -f $OVERRIDE ]; then
        : # user override latched for this plug session, do nothing
      elif [ "$cap" -ge "$HIGH" ] && is_charging "$cur"; then
        if [ ! -f $HOLDING ]; then
          log "cap=$cap charging -> bypass ON (cap ${HIGH}%)"
          echo 1 > $NODE
          touch $HOLDING
          grace=$GRACE_POLLS
          sleep 30
        else
          # Holding but current flowing past grace: user released bypass.
          log "manual bypass-OFF detected -> override till unplug"
          touch $OVERRIDE
          rm -f $HOLDING
        fi
      elif [ "$cap" -le "$LOW" ] && ! is_charging "$cur"; then
        if [ -f $HOLDING ]; then
          log "cap=$cap suspended -> bypass OFF (resume at ${LOW}%)"
          echo 0 > $NODE
          rm -f $HOLDING
          sleep 30
        fi
        # else: suspended below resume level by your own hand -> left alone
      else
        : # deadband, or full (100%, ~0 mA trickle): no action
      fi
    else
      # Unplugged: clear session state.
      rm -f $HOLDING $OVERRIDE
      grace=0
    fi

    # Live status: module list emoji (WebUI reads live via ksu.exec).
    if [ "$usb" != "1" ]; then
      ST="🔌 unplugged"
    elif [ -f $OVERRIDE ]; then
      ST="🔓 override till unplug (${cap:-?}%)"
    elif [ -f $HOLDING ]; then
      ST="⛔ bypass ON, holding ${cap:-?}%"
    elif [ -n "$cur" ] && is_charging "$cur"; then
      ST="🔋 charging ${cap:-?}%"
    else
      ST="⏸ idle ${cap:-?}%"
    fi
    update_desc "$ST" "$BASE_DESC"

    sleep $POLL
  done
}

loop &

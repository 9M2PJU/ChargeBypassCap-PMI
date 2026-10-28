#!/system/bin/sh
# KernelSU uninstall script: stop the daemon, remove state.
pkill -f modules/chargebypasscap-re404/bypasscap.sh
rm -rf /data/adb/chargebypasscap-re404

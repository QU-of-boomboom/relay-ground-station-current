#!/bin/sh
# Experimental board-specific start; never changes BOOT or the kernel image.
set -eu
O=/root/relay-wifi-modules-20261010-01
AP=$O/ap_20261011
export LD_LIBRARY_PATH=$O/userland/usr/lib/aarch64-linux-gnu:$O/userland/lib/aarch64-linux-gnu
cd "$O"
sha256sum -c "$AP/modules.sha256"
for service in hostapd dnsmasq; do
 if [ -f "$AP/$service.pid" ] && kill -0 "$(cat "$AP/$service.pid")" 2>/dev/null; then
  echo "Service PID is alive; check status before starting again: $service" >&2; exit 1
 fi
done
[ -f "$AP/firmware_path_before_start" ] || cat /sys/module/firmware_class/parameters/path > "$AP/firmware_path_before_start"
printf '%s' "$O/regdb_current/lib/firmware" > /sys/module/firmware_class/parameters/path
[ -d /sys/module/relay_sha256 ] || insmod "$O/sha256_backport/relay_sha256.ko"
[ -d /sys/module/relay_regdb_verify ] || insmod "$O/regdb_backport/relay_regdb_verify.ko"
[ -d /sys/module/cfg80211 ] || insmod "$O/net/wireless/cfg80211.ko"
[ -d /sys/module/8821cu ] || insmod "$O/driver/8821cu.ko" rtw_power_mgnt=0 rtw_enusbss=0
"$O/userland/sbin/iw" reg set CN
ip address replace 192.168.127.1/24 dev wlan0
"$O/userland/usr/sbin/hostapd" -B -P "$AP/hostapd.pid" -f "$AP/hostapd_restart.log" "$AP/hostapd.conf"
"$O/userland/usr/sbin/dnsmasq" --conf-file="$AP/dnsmasq.conf"
"$O/userland/sbin/iw" dev wlan0 info

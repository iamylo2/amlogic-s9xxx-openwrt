#!/bin/sh
# Penjaga uplink Wi-Fi (dongle USB sebagai STA) — versi generik.
# Dipanggil oleh /etc/hotplug.d/usb/20-wifi-uplink (ACTION=add) dan cron */5.
# Tidak mengunci IP, gateway, MAC, atau nama section: semuanya dibaca dari UCI
# yang diisi ylo-provision.sh. Menangani IP hilang, path UCI bergeser karena
# dongle pindah port, dan antarmuka tidak naik setelah boot.

log() { logger -t uplink-guard "$*"; }

STA=$(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.mode='sta'$/\1/p" | head -1)
[ -n "$STA" ] || { log "tidak ada wifi-iface mode sta, lewati"; exit 0; }

DEV=$(uci -q get "wireless.$STA.device")
NET=$(uci -q get "wireless.$STA.network")
IP=$(uci -q get "network.$NET.ipaddr")
GW=$(uci -q get "network.$NET.gateway")
[ -n "$DEV" ] && [ -n "$IP" ] || { log "uplink belum dikonfigurasi, lewati"; exit 0; }

up() {
	ip -4 addr show 2>/dev/null | grep -q "inet $IP/" || return 1
	[ -z "$GW" ] || ping -c2 -W2 "$GW" >/dev/null 2>&1
}

up && exit 0

# satu proses saja (hotplug bisa bertumpuk dengan cron)
LOCK=${LOCK:-/var/run/uplink-guard.lock}
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
up && exit 0

# driver dongle yang didukung image ini
modprobe rtl8xxxu 2>/dev/null
modprobe rtw88_8822bu 2>/dev/null

# path UCI mengikuti tempat phy dongle benar-benar menempel; identitasnya MAC,
# bukan nomor phy (berubah tiap boot) dan bukan nomor port (berubah saat pindah hub)
MAC=$(uci -q get "wireless.$DEV.macaddr")
if [ -n "$MAC" ]; then
	cur=$(uci -q get "wireless.$DEV.path")
	for phy in /sys/class/ieee80211/*; do
		[ "$(cat "$phy/macaddress" 2>/dev/null)" = "$MAC" ] || continue
		p=$(readlink -f "$phy/device" 2>/dev/null | sed 's#^/sys/devices/##')
		[ -n "$p" ] || break
		if [ "$p" != "$cur" ]; then
			uci set "wireless.$DEV.path=$p"
			uci commit wireless
			log "path dongle diperbaiki: $cur -> $p"
		fi
		break
	done
fi

wifi up "$DEV" >/dev/null 2>&1
i=0
while [ "$i" -lt 8 ]; do
	sleep 3
	up && { log "uplink pulih"; exit 0; }
	i=$((i + 1))
done

wifi reload >/dev/null 2>&1
sleep 15
up && { log "uplink pulih setelah reload"; exit 0; }
log "uplink BELUM pulih, perlu tindakan manual"
exit 0

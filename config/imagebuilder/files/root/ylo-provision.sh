#!/bin/sh
# ylo-provision.sh — konfigurasi site untuk image ylo-wrt (OpenWrt 24.10 + kernel flippy).
# Jalankan SEKALI sesudah flash: ubah blok KONFIG lalu `sh /root/ylo-provision.sh`.
# Idempoten: aman dijalankan ulang. Tidak menyentuh kartu/partisi bila sudah benar.
set -u

# ============================ KONFIG (ubah per site) ============================
LAN_IP="192.168.82.254"          # gateway br-lan. JANGAN memakai IP yang sudah ada di site
LAN_MASK="255.255.255.0"
SITE_HOSTNAME="ylo-wrt"

UPLINK_SSID="Yaibna_5G"
UPLINK_PSK="ISI_SANDI"
UPLINK_BSSID="B4:14:E6:8B:31:71"  # kosongkan bila tidak mau dikunci
UPLINK_IP="192.168.100.236"       # IP statis di subnet AP uplink
UPLINK_GW="192.168.100.1"
UPLINK_METRIC="60"

SQM_DOWN="8000"                   # Kbps, ±90% kapasitas terukur
SQM_UP="7000"

AGH_UPSTREAM=""                   # mis. https://dns.quad9.net/dns-query ; kosong = biarkan
TS_AUTHKEY=""                     # kosongkan bila Tailscale diaktifkan nanti dari CLI
# ================================================================================

log() { echo "[provision] $*"; }
die() { echo "[provision] GAGAL: $*" >&2; exit 1; }
need() { [ -n "$(eval echo \"\$$1\")" ] || die "variabel $1 kosong"; }

[ "$UPLINK_PSK" = "ISI_SANDI" ] && die "UPLINK_PSK belum diisi"

# ---------- 1. partisi rootfs: penuhi seluruh kartu ----------
SRC=$(findmnt -n -o SOURCE /)
DEV=$(echo "$SRC" | sed 's/p[0-9]*$//')
if [ -b "$DEV" ]; then
	cur_end=$(parted -s "$DEV" unit s print 2>/dev/null | awk '/^ 2:/{print $3}' | tr -d 's')
	disk_end=$(parted -s "$DEV" unit s print 2>/dev/null | awk '/^Disk \/|^Disk \/dev/{print $3}' | tr -d 's')
	if [ -n "$cur_end" ] && [ -n "$disk_end" ] && [ "$cur_end" -lt $((disk_end - 2048)) ]; then
		log "memperluas p2: $cur_end -> ujung kartu"
		parted ---pretend-input-tty "$DEV" resizepart 2 100% <<-EOF >/dev/null 2>&1
		Yes
		EOF
		resize2fs "$SRC" >/dev/null 2>&1 || true
		btrfs filesystem resize max / >/dev/null 2>&1 || true
	else
		log "partisi sudah memenuhi kartu"
	fi
else
	log "perangkat root bukan block device, langkah partisi dilewati"
fi

# ---------- 2. hostname + LAN ----------
uci set system.@system[0].hostname="$SITE_HOSTNAME"
uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask="$LAN_MASK"
uci -q delete network.lan.ip6assign
uci -q delete network.globals.ula_prefix
log "LAN $LAN_IP/24, hostname $SITE_HOSTNAME"

# ---------- 3. IPv6 mati, lo tetap hidup ----------
{
	echo 'net.ipv6.conf.default.disable_ipv6 = 1'
	for i in /sys/class/net/*; do
		n=$(basename "$i")
		case "$n" in lo|tailscale0) continue;; esac
		echo "net.ipv6.conf.$n.disable_ipv6 = 1"
	done
} > /etc/sysctl.d/99-no-ipv6.conf
sysctl -qw net.ipv6.conf.default.disable_ipv6=1 2>/dev/null
for i in /sys/class/net/*; do
	n=$(basename "$i")
	case "$n" in lo|tailscale0) continue;; esac
	sysctl -qw net.ipv6.conf."$n".disable_ipv6=1 2>/dev/null
done
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
log "IPv6 dimatikan kecuali lo/tailscale0"

# ---------- 4. uplink Wi-Fi (STA) ----------
modprobe rtl8xxxu 2>/dev/null
modprobe rtw88_8822bu 2>/dev/null
sleep 3

# cari phy dongle USB (bukan radio SDIO internal) untuk mengambil MAC-nya
PHY=""; MAC=""
for p in /sys/class/ieee80211/*; do
	drv=$(basename "$(readlink -f "$p/device/driver" 2>/dev/null)" 2>/dev/null)
	case "$drv" in rtl8xxxu|rtw88_8822bu) PHY=$(basename "$p"); MAC=$(cat "$p/macaddress" 2>/dev/null);; esac
	[ -n "$MAC" ] && break
done
[ -n "$PHY" ] || die "dongle Wi-Fi USB tidak terdeteksi (cek lsusb / dmesg)"
log "dongle: $PHY mac $MAC"

uci -q delete wireless.yaibna 2>/dev/null
uci -q delete wireless.yaibna_sta 2>/dev/null
uci set wireless.yaibna=wifi-device
uci set wireless.yaibna.type='mac80211'
uci set wireless.yaibna.path=$(readlink -f "/sys/class/ieee80211/$PHY/device" | sed 's#^/sys/devices/##')
uci set wireless.yaibna.band='2g'
uci set wireless.yaibna.channel='6'
uci set wireless.yaibna.htmode='HT20'
uci set wireless.yaibna.country='SG'
uci set wireless.yaibna.disabled='0'
uci set wireless.yaibna.macaddr="$MAC"

uci set wireless.yaibna_sta=wifi-iface
uci set wireless.yaibna_sta.device='yaibna'
uci set wireless.yaibna_sta.mode='sta'
uci set wireless.yaibna_sta.ssid="$UPLINK_SSID"
[ -n "$UPLINK_BSSID" ] && uci set wireless.yaibna_sta.bssid="$UPLINK_BSSID"
uci set wireless.yaibna_sta.encryption='psk2'
uci set wireless.yaibna_sta.key="$UPLINK_PSK"
uci set wireless.yaibna_sta.network='wanwifi'
uci set wireless.yaibna_sta.ifname='wsta0'
uci set wireless.yaibna_sta.disabled='0'

uci set network.wanwifi=interface
uci set network.wanwifi.proto='static'
uci set network.wanwifi.device='wsta0'
uci set network.wanwifi.ipaddr="$UPLINK_IP"
uci set network.wanwifi.netmask='255.255.255.0'
uci set network.wanwifi.gateway="$UPLINK_GW"
uci set network.wanwifi.metric="$UPLINK_METRIC"
uci -q delete network.wanwifi.dns
uci add_list network.wanwifi.dns="$UPLINK_GW"

# zona wan: masukkan uplink
uci -q delete firewall.wanwifi
uci set firewall.wanwifi=zone
uci set firewall.wanwifi.name='wanwifi'
uci set firewall.wanwifi.input='REJECT'
uci set firewall.wanwifi.output='ACCEPT'
uci set firewall.wanwifi.forward='REJECT'
uci set firewall.wanwifi.masq='1'
uci set firewall.wanwifi.mtu_fix='1'
uci add_list firewall.wanwifi.network='wanwifi'
log "uplink $UPLINK_SSID → $UPLINK_IP"

# ---------- 5. SQM cake pada netdev uplink ----------
uci -q delete sqm.wanwifi
uci set sqm.wanwifi=queue
uci set sqm.wanwifi.enabled='1'
uci set sqm.wanwifi.interface='wsta0'
uci set sqm.wanwifi.download="$SQM_DOWN"
uci set sqm.wanwifi.upload="$SQM_UP"
uci set sqm.wanwifi.qdisc='cake'
uci set sqm.wanwifi.script='piece_of_cake.qos'
uci set sqm.wanwifi.linklayer='none'
uci set sqm.wanwifi.ingress_ecn='ECN'
uci set sqm.wanwifi.egress_ecn='ECN'
log "SQM cake ${SQM_DOWN}/${SQM_UP} kbit pada wsta0"

# ---------- 6. AdGuard sebagai resolver site ----------
if [ -f /etc/adguardhome.yaml ]; then
	awk -v ip="$LAN_IP" -v up="$AGH_UPSTREAM" '
		/^[[:space:]]+bind_hosts:/ {inb=1; print; print "    - " ip; print "    - 127.0.0.1"; next}
		inb && /^[[:space:]]+- / {next}
		inb && !/^[[:space:]]+- / {inb=0}
		/^[[:space:]]+upstream_dns:/ && up!="" {inu=1; print; print "    - " up; next}
		inu && /^[[:space:]]+- / {next}
		inu && !/^[[:space:]]+- / {inu=0}
		{print}
	' /etc/adguardhome.yaml > /etc/adguardhome.yaml.new && mv /etc/adguardhome.yaml.new /etc/adguardhome.yaml
	/etc/init.d/adguardhome restart >/dev/null 2>&1
	sleep 3
	uci set dhcp.@dnsmasq[0].port='0'
	log "AdGuard memegang :53, dnsmasq dipindah ke port 0"
else
	log "PERINGATAN: /etc/adguardhome.yaml tidak ada, dnsmasq dibiarkan di :53"
fi
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option="6,$LAN_IP"

# ---------- 7. vnstat ----------
uci -q delete vnstat.@vnstat[0]
uci set vnstat.@vnstat[0]=vnstat
uci add_list vnstat.@vnstat[0].interface='br-lan'
uci add_list vnstat.@vnstat[0].interface='wsta0'

# ---------- 8. layanan yang harus mati ----------
/etc/init.d/modemmanager disable >/dev/null 2>&1
/etc/init.d/modemmanager stop >/dev/null 2>&1
uci set openclash.config.enable='0' 2>/dev/null || true
/etc/init.d/openclash disable >/dev/null 2>&1
/etc/init.d/openclash stop >/dev/null 2>&1
uci set openclash.config.dnsmasq_server='127.0.0.1#53' 2>/dev/null || true
uci set openclash.config.dnsmasq_noresolv='1' 2>/dev/null || true
log "ModemManager dan OpenClash dimatikan (aktifkan hanya bila dipakai)"

# ---------- 9. modul 8189fs: dipasang, tidak dimuat otomatis ----------
if [ -f /root/8189fs.ko ] && [ ! -f "/lib/modules/$(uname -r)/8189fs.ko" ]; then
	K="/lib/modules/$(uname -r)"
	mkdir -p "$K/kernel/drivers/net/wireless/realtek/rtl8189fs"
	cp /root/8189fs.ko "$K/kernel/drivers/net/wireless/realtek/rtl8189fs/"
	depmod -a 2>/dev/null
	log "modul 8189fs dipasang (tidak di-autoload; aktifkan: modprobe 8189fs && wifi config)"
fi

# ---------- 10. terapkan ----------
uci commit
/etc/init.d/network reload >/dev/null 2>&1
wifi reload >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1
/etc/init.d/sqm restart >/dev/null 2>&1
/etc/init.d/vnstat restart >/dev/null 2>&1

if [ -n "$TS_AUTHKEY" ]; then
	tailscale up --authkey "$TS_AUTHKEY" --hostname="$SITE_HOSTNAME" --accept-dns=false >/dev/null 2>&1 &&
		log "Tailscale aktif" || log "PERINGATAN: tailscale up gagal, ulangi manual"
fi

sleep 10
# ---------- 11. ringkasan ----------
echo "==== RINGKASAN ===="
ip -br addr
echo "-- rute:"; ip route
echo "-- country:"; iw reg get 2>/dev/null | head -2
echo "-- qdisc:"; tc qdisc show dev wsta0 2>/dev/null | head -3
echo "-- dns:"; nslookup example.org 127.0.0.1 2>&1 | tail -3
echo "-- modem:"; mmcli -L 2>&1 | head -2
echo "-- tailscale:"; tailscale status 2>&1 | head -2
echo "-- partisi:"; df -h /
echo "==================="
log "selesai. Uji: ping gateway uplink, buka LuCI, cek Observium/SNMP"

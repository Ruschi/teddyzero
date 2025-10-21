#!/bin/bash
set -e

# Config source: use local ./config/ if present else download from GitHub raw
# Set your config repo raw base here:
GITHUB_RAW_BASE="https://raw.githubusercontent.com/Ruschi/teddyzero/refs/heads/main/config"

fetch_or_copy() {
  local name="$1"
  local dest="$2"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local local_path="$script_dir/config/$name"

  if [ -f "$local_path" ]; then
    echo "Using local config $local_path -> $dest"
    install -m 644 "$local_path" "$dest"
  elif [ -n "$GITHUB_RAW_BASE" ]; then
    echo "Downloading $name from $GITHUB_RAW_BASE -> $dest"
    mkdir -p "$(dirname "$dest")"
    wget -q -O "$dest" "$GITHUB_RAW_BASE/$name"
    chmod 644 "$dest" || true
  else
    echo "Fehler: Konfigurationsdatei $name nicht gefunden und GITHUB_RAW_BASE nicht gesetzt."
    exit 1
  fi

  # Replace placeholders for COUNTRY if present
  if grep -q "\\$\\{COUNTRY\\}" "$dest" 2>/dev/null || grep -q "__COUNTRY__" "$dest" 2>/dev/null; then
    sed -i "s|\\$\\{COUNTRY\\}|${COUNTRY}|g" "$dest" || true
    sed -i "s|__COUNTRY__|${COUNTRY}|g" "$dest" || true
  fi
}

echo "=== TeddyCloud Pi Zero W2 Setup ==="

# --- Root Check ---
if [ "$EUID" -ne 0 ]; then
  echo "Bitte mit sudo ausführen!"
  exit 1
fi

# --- 1. System Update & Cleanup ---
apt update
apt full-upgrade -y
apt purge -y triggerhappy dphys-swapfile avahi-daemon cups \
  rpcbind nfs-common samba* bluez* x11-* lightdm libreoffice* \
  wolfram-engine chromium* || true
apt autoremove -y
apt clean
systemctl disable apt-daily.service apt-daily.timer apt-daily-upgrade.timer man-db.timer || true

# --- 2. WLAN-Config vom Imager übernehmen ---
IMAGER_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
WLAN1_CONF="/etc/wpa_supplicant/wpa_supplicant-wlan1.conf"

if [ ! -f "$IMAGER_CONF" ]; then
  echo "Fehler: $IMAGER_CONF nicht gefunden."
  echo "Bitte WLAN-Konfiguration im Raspberry Pi Imager aktivieren!"
  exit 1
fi

SSID=$(grep -oP 'ssid="\K[^"]+' "$IMAGER_CONF" || true)
COUNTRY=$(grep -oP 'country=\K[A-Z]+' "$IMAGER_CONF" || echo "DE")

echo "Verwende WLAN-SSID=$SSID, COUNTRY=$COUNTRY"
cp "$IMAGER_CONF" "$WLAN1_CONF"
chmod 600 "$WLAN1_CONF"

# --- 3. Notwendige Pakete installieren ---
apt install -y hostapd dnsmasq git build-essential \
  libssl-dev libcurl4-openssl-dev libpugixml-dev libspdlog-dev \
  zlib1g-dev libmicrohttpd-dev wget unzip dhcpcd5 isc-dhcp-client

systemctl stop hostapd || true
systemctl stop dnsmasq || true

# --- 4. Firmware für MT7601 installieren ---
mkdir -p /lib/firmware/mediatek
if [ ! -f /lib/firmware/mediatek/mt7601u.bin ]; then
  wget -q -O /lib/firmware/mediatek/mt7601u.bin \
    "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7601u.bin"
  ln -sf /lib/firmware/mediatek/mt7601u.bin /lib/firmware/mt7601u.bin
fi

# --- 5. AP- und DNS-Konfiguration ---

iw reg set DE

# Write dhcpcd.conf (from config folder or GitHub)
fetch_or_copy "dhcpcd.conf" "/etc/dhcpcd.conf"

# hostapd config
mkdir -p /etc/hostapd
fetch_or_copy "hostapd.conf" "/etc/hostapd/hostapd.conf"
sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig || true
fetch_or_copy "dnsmasq.conf" "/etc/dnsmasq.conf"

# --- 6. wlan1 hochfahren (kein NAT) ---
fetch_or_copy "wlan1-up.service" "/etc/systemd/system/wlan1-up.service"

systemctl daemon-reload
systemctl enable wlan1-up.service

# --- Fix Wi-Fi interface roles (wlan0 = AP, wlan1 = Internet) ---

# Stop any running wpa_supplicant instance that might have grabbed wlan0
systemctl stop wpa_supplicant@wlan0.service || true
systemctl disable wpa_supplicant@wlan0.service || true
killall wpa_supplicant || true

# Ensure wlan0 has static IP and no wpa_supplicant hook
fetch_or_copy "dhcpcd.conf" "/etc/dhcpcd.conf"

# Restart DHCP client to apply
systemctl restart dhcpcd || true

# Make sure wlan0 is up and hostapd can claim it
ip link set wlan0 up || true

# Restart hostapd cleanly
systemctl restart hostapd
sleep 3

# Verify that wlan0 is in AP mode (for logging/debug)
iw dev wlan0 info || true

# --- 7. TeddyCloud Binary bauen (nur Binary!) ---
if [ ! -d /opt/teddycloud ]; then
  git clone https://github.com/toniebox-reverse-engineering/teddycloud.git /opt/teddycloud
fi

cd /opt/teddycloud
git submodule update --init --recursive

# Binary bauen
make -j$(nproc) bin/teddycloud

sudo cp bin/teddycloud /usr/local/bin/teddycloud
sudo chmod +x /usr/local/bin/teddycloud

# --- 8. Fertige Web-App herunterladen und installieren ---
WEB_URL="https://github.com/Ruschi/teddycloud_web/releases/latest/download/web-build.zip"
sudo mkdir -p /etc/teddycloud/web
wget -O /tmp/web-build.zip "$WEB_URL"
sudo unzip -o /tmp/web-build.zip -d /etc/teddycloud/web
rm /tmp/web-build.zip

# Konfiguration kopieren
sudo cp -r config/* /etc/teddycloud/ || true

# --- 9. Systemd-Service für TeddyCloud ---
fetch_or_copy "teddycloud.service" "/etc/systemd/system/teddycloud.service"

systemctl daemon-reload
systemctl enable teddycloud.service

# --- 10. Dienste aktivieren ---
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq

echo "=== ✅ Setup abgeschlossen ==="
echo "AP: wlan0=PiCloud, DNS-Rewrite aktiv."
echo "WLAN1 nutzt dein Imager-WLAN für Internetzugang."
echo "TeddyCloud Server läuft mit fertiger Web-App."
read -p "Jetzt neustarten? (y/N): " ANS
if [[ "$ANS" =~ ^[Yy]$ ]]; then
  reboot
fi

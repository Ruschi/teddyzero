#!/bin/bash
set -e

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

cat > /etc/dhcpcd.conf <<'EOF'
interface wlan0
    static ip_address=192.168.4.1/24
    nohook wpa_supplicant
EOF

cat > /etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=PiCloud
hw_mode=g
channel=6
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
country_code=${COUNTRY}
EOF
sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig || true
cat > /etc/dnsmasq.conf <<'EOF'
interface=wlan0
bind-interfaces
server=8.8.8.8
domain-needed
bogus-priv
dhcp-range=192.168.4.10,192.168.4.100,255.255.255.0,24h
dhcp-option=3,192.168.4.1
dhcp-option=6,192.168.4.1
address=/#/192.168.4.1
EOF

# --- 6. wlan1 hochfahren (kein NAT) ---
cat > /etc/systemd/system/wlan1-up.service <<'EOF'
[Unit]
Description=Bring up wlan1 using existing wpa_supplicant config
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/wpa_supplicant -B -i wlan1 -c /etc/wpa_supplicant/wpa_supplicant-wlan1.conf
ExecStartPost=/sbin/dhclient wlan1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wlan1-up.service


# --- Fix Wi-Fi interface roles (wlan0 = AP, wlan1 = Internet) ---

# Stop any running wpa_supplicant instance that might have grabbed wlan0
systemctl stop wpa_supplicant@wlan0.service || true
systemctl disable wpa_supplicant@wlan0.service || true
killall wpa_supplicant || true

# Ensure wlan0 has static IP and no wpa_supplicant hook
cat > /etc/dhcpcd.conf <<'EOF'
interface wlan0
    static ip_address=192.168.4.1/24
    nohook wpa_supplicant
EOF

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
cat > /etc/systemd/system/teddycloud.service <<'EOF'
[Unit]
Description=TeddyCloud Server
After=network.target

[Service]
ExecStart=/usr/local/bin/teddycloud --config /etc/teddycloud/config.json
Restart=always
User=root
WorkingDirectory=/etc/teddycloud

[Install]
WantedBy=multi-user.target
EOF

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

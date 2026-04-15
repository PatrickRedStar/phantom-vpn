#!/bin/sh
# GhostStream VPN — OpenWrt one-liner installer
# Usage: wget -O /tmp/gs-install.sh https://github.com/PatrickRedStar/phantom-vpn/releases/latest/download/ghoststream-install.sh && sh /tmp/gs-install.sh
set -e

GITHUB="https://github.com/PatrickRedStar/phantom-vpn/releases/latest/download"

echo ""
echo "=== GhostStream VPN installer for OpenWrt ==="
echo ""

# 1. Проверяем что мы на OpenWrt
if [ ! -f /etc/openwrt_release ]; then
    echo "ERROR: /etc/openwrt_release not found. This script is for OpenWrt only." >&2
    exit 1
fi

# 2. Показываем версию и target
. /etc/openwrt_release
echo "OpenWrt version : ${DISTRIB_RELEASE}"
echo "Target          : ${DISTRIB_TARGET}"
echo "Arch            : ${DISTRIB_ARCH}"
echo ""

# 3. Определяем архитектуру
ARCH="$(uname -m)"
case "${ARCH}" in
    mips|mipsel)    BIN="ghoststream-mipsel" ;;
    aarch64)        BIN="ghoststream-aarch64" ;;
    armv7l|armv7)   BIN="ghoststream-armv7" ;;
    x86_64)         BIN="ghoststream-x86_64" ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        echo "Supported: mips/mipsel, aarch64, armv7l, x86_64" >&2
        exit 1
        ;;
esac

echo "Binary to fetch : ${BIN}"
echo ""

# 4. Скачиваем бинарник
echo "[1/4] Downloading ${BIN} → /usr/bin/ghoststream ..."
wget -O /usr/bin/ghoststream "${GITHUB}/${BIN}" || {
    echo "ERROR: Failed to download ${GITHUB}/${BIN}" >&2
    exit 1
}
chmod 0755 /usr/bin/ghoststream
echo "      OK"

# 5. Скачиваем netifd proto handler
echo "[2/4] Downloading netifd handler → /lib/netifd/proto/ghoststream.sh ..."
mkdir -p /lib/netifd/proto
wget -O /lib/netifd/proto/ghoststream.sh \
    "${GITHUB}/ghoststream.sh" || {
    echo "ERROR: Failed to download netifd handler" >&2
    exit 1
}
chmod 0755 /lib/netifd/proto/ghoststream.sh
echo "      OK"

# 6. Скачиваем LuCI JS
echo "[3/4] Downloading LuCI JS → /www/luci-static/resources/protocol/ghoststream.js ..."
mkdir -p /www/luci-static/resources/protocol
wget -O /www/luci-static/resources/protocol/ghoststream.js \
    "${GITHUB}/ghoststream.js" || {
    echo "ERROR: Failed to download LuCI JS" >&2
    exit 1
}
echo "      OK"

# 7. Скачиваем ACL
echo "[4/4] Downloading ACL → /usr/share/rpcd/acl.d/luci-proto-ghoststream.json ..."
mkdir -p /usr/share/rpcd/acl.d
wget -O /usr/share/rpcd/acl.d/luci-proto-ghoststream.json \
    "${GITHUB}/luci-proto-ghoststream.json" || {
    echo "ERROR: Failed to download ACL" >&2
    exit 1
}
echo "      OK"

echo ""
echo "All files installed successfully."
echo ""

# 8. Спрашиваем connection string
printf "Connection string (paste and press Enter, or leave empty to skip): "
read -r CONN_STRING

if [ -n "${CONN_STRING}" ]; then
    echo ""
    echo "Configuring UCI interface and firewall ..."

    # 9. Создаём UCI interface
    uci set network.ghoststream0=interface
    uci set network.ghoststream0.proto='ghoststream'
    uci set network.ghoststream0.connection_string="${CONN_STRING}"
    uci set network.ghoststream0.mtu='1350'

    # Firewall zone
    uci set firewall.gs_zone=zone
    uci set firewall.gs_zone.name='ghoststream'
    uci set firewall.gs_zone.network='ghoststream0'
    uci set firewall.gs_zone.input='REJECT'
    uci set firewall.gs_zone.output='ACCEPT'
    uci set firewall.gs_zone.forward='REJECT'
    uci set firewall.gs_zone.masq='1'
    uci set firewall.gs_zone.mtu_fix='1'

    # Forwarding lan → ghoststream
    uci set firewall.gs_fwd=forwarding
    uci set firewall.gs_fwd.src='lan'
    uci set firewall.gs_fwd.dest='ghoststream'

    uci commit network
    uci commit firewall

    echo "UCI configuration saved."
    echo ""

    # 10. Рестартуем rpcd и перезагружаем network
    echo "Restarting rpcd ..."
    /etc/init.d/rpcd restart 2>/dev/null || true

    echo "Reloading network ..."
    /etc/init.d/network reload

    echo ""
    echo "Interface ghoststream0 configured and network reloaded."
else
    echo ""
    echo "Skipped UCI configuration (no connection string provided)."
    echo "You can configure manually later:"
    echo "  uci set network.ghoststream0=interface"
    echo "  uci set network.ghoststream0.proto='ghoststream'"
    echo "  uci set network.ghoststream0.connection_string='<your_conn_string>'"
    echo "  uci set network.ghoststream0.mtu='1350'"
    echo "  uci commit network && /etc/init.d/network reload"
fi

# 11. Инструкция
echo ""
echo "============================================================"
echo " GhostStream VPN installation complete!"
echo "============================================================"
echo ""
echo " LuCI:  Network → Interfaces → ghoststream0"
echo "        (Protocol: GhostStream)"
echo ""
echo " CLI commands:"
echo "   ifup ghoststream0     — bring up VPN interface"
echo "   ifdown ghoststream0   — bring down VPN interface"
echo "   logread | grep ghost  — view VPN logs"
echo ""
echo " If LuCI does not show the protocol, clear browser cache"
echo " or run:  /etc/init.d/rpcd restart"
echo ""

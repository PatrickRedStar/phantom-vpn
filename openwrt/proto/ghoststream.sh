#!/bin/sh
# GhostStream netifd protocol handler
# Install to: /lib/netifd/proto/ghoststream.sh

. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

proto_ghoststream_init_config() {
    proto_config_add_string 'connection_string'
    proto_config_add_int 'mtu'
    available=1
    no_device=1
}

proto_ghoststream_setup() {
    local config="$1"
    local iface="$2"

    local connection_string mtu
    json_get_vars connection_string mtu

    [ -z "$connection_string" ] && {
        echo "GhostStream: connection_string is required" >&2
        proto_notify_error "$config" "NO_CONNECTION_STRING"
        proto_block_restart "$config"
        return 1
    }

    [ -z "$mtu" ] && mtu=1350

    local tun_name="gs-${config}"

    # Parse tunnel address from connection string (ghs:// URL)
    local tun_addr
    tun_addr=$(/usr/bin/ghoststream --print-tun-addr "$connection_string" 2>/dev/null)
    [ -z "$tun_addr" ] && tun_addr="10.7.0.2/24"

    local ip_addr="${tun_addr%%/*}"
    local prefix="${tun_addr##*/}"
    local gateway
    gateway=$(echo "$ip_addr" | awk -F. '{printf "%s.%s.%s.1", $1, $2, $3}')

    # Start daemon
    proto_run_command "$config" /usr/bin/ghoststream \
        --conn-string "$connection_string" \
        --tun-name "$tun_name" \
        --mtu "$mtu"

    # Wait for TUN interface to appear
    local waited=0
    while [ ! -d "/sys/class/net/${tun_name}" ] && [ "$waited" -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if [ ! -d "/sys/class/net/${tun_name}" ]; then
        echo "GhostStream: TUN ${tun_name} did not appear after ${waited}s" >&2
        proto_notify_error "$config" "TUN_FAILED"
        proto_kill_command "$config"
        return 1
    fi

    proto_init_update "$tun_name" 1
    proto_add_ipv4_address "$ip_addr" "$prefix"
    proto_add_dns_server "$gateway"
    # NOTE: No default route added here. Configure routing via LuCI:
    # Set interface metric lower than WAN (e.g. 10) to make it the default route.
    # OpenWrt handles the VPN server route exception automatically via metric.
    proto_send_update "$config"
}

proto_ghoststream_teardown() {
    local config="$1"
    proto_kill_command "$config"
}

add_protocol ghoststream

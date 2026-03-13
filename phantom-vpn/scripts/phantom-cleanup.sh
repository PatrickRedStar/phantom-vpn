#!/bin/bash
# phantom-cleanup.sh — Restores routing rules after a client crash (SIGKILL).
# Reads state from /run/phantom-vpn-routes.json written by the client.

STATE_FILE="/run/phantom-vpn-routes.json"
FWMARK="0x50"
ROUTE_TABLE="51820"

if [ ! -f "$STATE_FILE" ]; then
    echo "No route state file found at $STATE_FILE — nothing to clean up."
    exit 0
fi

echo "Reading route state from $STATE_FILE..."

SERVER_IP=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('server_ip',''))" 2>/dev/null)
OLD_GW=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('old_gw','') or '')" 2>/dev/null)
OLD_DEV=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('old_dev','') or '')" 2>/dev/null)
TUN_NAME=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('tun_name',''))" 2>/dev/null)
CONNMARK=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('connmark_rules_installed', False))" 2>/dev/null)

echo "State: server=$SERVER_IP gw=$OLD_GW dev=$OLD_DEV tun=$TUN_NAME connmark=$CONNMARK"

# Remove policy rules
echo "Removing ip rules..."
ip rule del not fwmark $FWMARK table $ROUTE_TABLE 2>/dev/null
ip rule del table main suppress_prefixlength 0 2>/dev/null

# Remove tunnel default route
echo "Removing tunnel default route..."
ip route del default dev "$TUN_NAME" table $ROUTE_TABLE 2>/dev/null

# Remove host route to server
if [ -n "$SERVER_IP" ] && [ -n "$OLD_GW" ]; then
    echo "Removing host route for $SERVER_IP..."
    ip route del "${SERVER_IP}/32" 2>/dev/null
fi

# Remove connmark rules
if [ "$CONNMARK" = "True" ] && [ -n "$OLD_DEV" ]; then
    echo "Removing iptables connmark rules..."
    iptables -t mangle -D PREROUTING -i "$OLD_DEV" -j CONNMARK --set-mark $FWMARK 2>/dev/null
    iptables -t mangle -D OUTPUT -m connmark --mark $FWMARK -j MARK --set-mark $FWMARK 2>/dev/null
fi

# Remove state file
rm -f "$STATE_FILE"

echo "Cleanup complete. Routes should be restored."

#!/bin/bash
# keepalived state-transition orchestrator for the HA NAT router.
# Usage: notify.sh {master|backup|fault|stop}
#
# master: assume the shared WAN identity. The synced lease is replayed
#         offline first (milliseconds, zero upstream packets) so planned
#         switchovers are seamless; dhcpcd then confirms it in the background.
# backup/fault/stop: relinquish the WAN identity without releasing the lease.

set -u

STATE="${1:?usage: notify.sh master|backup|fault|stop}"
WAN_IF=end0

[ -r /etc/ha-router/node.env ] && . /etc/ha-router/node.env

mkdir -p /run/ha-router
echo "$STATE" > /run/ha-router/state
logger -t ha-router "keepalived transition -> $STATE"

wan_takeover() {
    # Clone the shared link-layer identity, then bring the WAN up.
    ip link set dev "$WAN_IF" address \
        "${WAN_MAC:?WAN_MAC not set - run ha-node-setup}"
    ip link set dev "$WAN_IF" up

    # Instant lease playback: configure the rsync-synced lease without
    # waiting for (or talking to) the ISP's rate-limited DHCP server. The
    # dhcpcd exit-hook captured these values at bind time.
    local ip_address="" subnet_cidr="" routers=""
    [ -r /var/lib/dhcpcd/ha-lease.env ] && . /var/lib/dhcpcd/ha-lease.env
    if [ -n "$ip_address" ]; then
        ip addr replace "${ip_address}/${subnet_cidr:-24}" dev "$WAN_IF"
        if [ -n "$routers" ]; then
            ip route replace default via "${routers%% *}" dev "$WAN_IF"
        fi
        arping -U -c 2 -I "$WAN_IF" "$ip_address" >/dev/null 2>&1 &
        logger -t ha-router \
            "WAN lease playback: ${ip_address}/${subnet_cidr:-24} via ${routers:-?}"
    else
        logger -t ha-router \
            "WAN lease playback: no saved lease; waiting on dhcpcd"
    fi

    # dhcpcd confirms the replayed lease upstream (one same-identity
    # DHCPREQUEST) and owns renewals from here; lastleaseextend keeps the
    # lease if the ISP stays silent.
    dhcpcd -b "$WAN_IF"

    # Commit the synced connection-tracking state into the kernel, flush the
    # stale internal cache, and resync (standard primary-backup sequence).
    conntrackd -c
    conntrackd -f
    conntrackd -R
}

wan_release() {
    # Stop dhcpcd WITHOUT sending DHCP_RELEASE, keeping the lease valid for
    # the peer, then drop the shared identity off the wire entirely.
    # dhcpcd 10 can leave its privileged/control proxy processes behind
    # after an interface-scoped exit; dhcpcd only ever manages the WAN on
    # this system, so make sure nothing survives.
    dhcpcd -x "$WAN_IF" 2>/dev/null
    pkill -x dhcpcd 2>/dev/null
    ip addr flush dev "$WAN_IF" 2>/dev/null
    ip link set dev "$WAN_IF" down 2>/dev/null

    # Pull a fresh copy of the connection table from the new master.
    conntrackd -n 2>/dev/null
}

case "$STATE" in
    master)
        wan_takeover
        ;;
    backup|fault|stop)
        wan_release
        ;;
esac

exit 0

#!/bin/bash
# Repeatable smoke test for the HA NAT router container.
#
# Builds the image against a stand-in bootc base (the real BASE chain is only
# available in CI) and verifies, inside a privileged container:
#   1. ha-node-setup renders valid keepalived/conntrackd configs
#   2. the nftables ruleset loads and contains the NAT rule
#   3. the full failover lifecycle against a real DHCP server (dnsmasq):
#      cold takeover -> lease + hook capture, demote -> clean release,
#      warm takeover -> instant offline lease playback (<1s),
#      background dhcpcd confirmation of the same lease upstream.
#
# Usage: ./smoke-test.sh [base-image]
#   base-image defaults to quay.io/almalinuxorg/almalinux-bootc:10
#
# Requires podman (a running podman machine on macOS).

set -euo pipefail

BASE="${1:-quay.io/almalinuxorg/almalinux-bootc:10}"
IMAGE="internet-smoke-test"
DIR="$(cd "$(dirname "$0")" && pwd)"

PODMAN="$(command -v podman || true)"
[ -z "$PODMAN" ] && [ -x /opt/podman/bin/podman ] && PODMAN=/opt/podman/bin/podman
if [ -z "$PODMAN" ]; then
    echo "smoke-test: podman not found" >&2
    exit 1
fi

echo "==> Building $IMAGE from BASE=$BASE"
"$PODMAN" build -q --build-arg BASE="$BASE" -t "$IMAGE" "$DIR"

echo "==> Running in-container test suite"
rc=0
"$PODMAN" run --rm -i --privileged "$IMAGE" bash -s <<'IN_CONTAINER' || rc=$?
set -u

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
wait_for() { # wait_for <seconds> <command...>
    local deadline=$(( $(date +%s) + $1 )); shift
    while ! "$@" >/dev/null 2>&1; do
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 1
    done
}

echo "--- environment ---"
dnf -y -q install dnsmasq >/dev/null 2>&1 || { echo "FATAL: cannot install dnsmasq"; exit 2; }

# Fake NICs matching the real hardware names, plus a veth WAN whose peer
# hosts dnsmasq playing the role of the rate-limited ISP DHCP server.
ip link add enu1u1 type dummy
ip link add enu1u2 type dummy
ip link set enu1u1 up
ip link set enu1u2 up
ip link add end0 type veth peer name wan0
ip addr add 203.0.113.1/24 dev wan0
ip link set wan0 up
dnsmasq --interface=wan0 --bind-interfaces \
    --dhcp-range=203.0.113.50,203.0.113.99,12h \
    --dhcp-option=option:router,203.0.113.1 --port=0
sleep 1

echo "--- 1. per-node setup + config validation ---"
check "ha-node-setup --node 1 runs" \
    ha-node-setup --node 1 --no-restart
check "node.env rendered" \
    grep -q "^WAN_MAC=" /etc/ha-router/node.env
keepalived --config-test=/tmp/ka.log -f /etc/keepalived/keepalived.conf
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "keepalived config valid (interfaces present)"
else
    bad "keepalived config-test rc=$rc"; cat /tmp/ka.log 2>/dev/null
fi
if timeout 3 conntrackd -C /etc/conntrackd/conntrackd.conf -d 2>&1 \
        | grep -qiE "parse|invalid config|error at line"; then
    bad "conntrackd config parse"
else
    ok "conntrackd config parses"
fi
ha-node-setup --node 1 --no-restart \
    --authorize-key "ssh-ed25519 AAAAC3TESTKEY root@peer" >/dev/null 2>&1
ha-node-setup --node 1 --no-restart \
    --authorize-key "ssh-ed25519 AAAAC3TESTKEY root@peer" >/dev/null 2>&1
check "authorize-key is idempotent" \
    test "$(grep -c TESTKEY "$(realpath -m /root)/.ssh/authorized_keys")" = 1

echo "--- 2. nftables ruleset ---"
check "router.nft loads" nft -f /etc/nftables/router.nft
check "masquerade rule present" \
    sh -c 'nft list ruleset | grep -q masquerade'
check "include wired into /etc/sysconfig/nftables.conf" \
    grep -q "/etc/nftables/router.nft" /etc/sysconfig/nftables.conf
# In production the ISP's DHCP server sits upstream of end0; in this test it
# runs in the same netns on wan0, where the router's input policy would
# (correctly) drop server-bound DHCP. Clear the ruleset for the lifecycle test.
nft flush ruleset

echo "--- 3. failover lifecycle ---"
# 3a. Cold takeover: no synced lease yet; dhcpcd must acquire one and the
# exit-hook must capture it for the peer.
/usr/libexec/ha-router/notify.sh master 2>/dev/null
check "cold: MAC cloned" \
    sh -c 'ip link show end0 | grep -q 02:11:22:33:44:55'
if wait_for 30 test -s /var/lib/dhcpcd/ha-lease.env; then
    ok "cold: lease acquired and captured by hook"
else
    bad "cold: no lease after 30s"
fi
. /var/lib/dhcpcd/ha-lease.env 2>/dev/null || true
LEASED_IP="${ip_address:-}"
check "cold: address configured" \
    sh -c "ip -4 addr show dev end0 | grep -q '$LEASED_IP'"

# 3b. Demotion: everything must be released without a DHCP_RELEASE.
/usr/libexec/ha-router/notify.sh backup 2>/dev/null
sleep 1
check "demote: dhcpcd fully stopped" sh -c '! pgrep -x dhcpcd'
check "demote: address released" \
    sh -c '! ip -4 addr show dev end0 | grep -q inet'
check "demote: link down" \
    sh -c 'ip link show end0 | grep -q "state DOWN"'
check "demote: state file" grep -qx backup /run/ha-router/state

# 3c. Warm takeover: the failover path. Offline lease playback must restore
# the exact same address in well under a second, before any DHCP exchange.
t0=$(date +%s%N)
/usr/libexec/ha-router/notify.sh master 2>/dev/null
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ "$ms" -lt 1000 ]; then
    ok "warm: takeover in ${ms}ms (<1s)"
else
    bad "warm: takeover took ${ms}ms"
fi
check "warm: same address replayed" \
    sh -c "ip -4 addr show dev end0 | grep -q '$LEASED_IP'"
check "warm: default route present" \
    sh -c 'ip route show default | grep -q end0'

# 3d. dhcpcd confirms the replayed lease upstream (INIT-REBOOT + ~5s ARP
# probe) and takes over the route without changing the address.
if wait_for 30 sh -c 'ip route show default | grep -q "proto dhcp"'; then
    ok "confirm: dhcpcd re-bound the lease upstream"
else
    bad "confirm: dhcpcd never confirmed the lease"
fi
check "confirm: address unchanged" \
    sh -c "ip -4 addr show dev end0 | grep -q '$LEASED_IP'"

# 3e. Final demotion must again leave nothing behind.
/usr/libexec/ha-router/notify.sh backup 2>/dev/null
sleep 1
check "final demote: dhcpcd fully stopped" sh -c '! pgrep -x dhcpcd'
check "final demote: link down" \
    sh -c 'ip link show end0 | grep -q "state DOWN"'

echo "--- results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
IN_CONTAINER
if [ "$rc" -eq 0 ]; then
    echo "==> smoke test PASSED"
else
    echo "==> smoke test FAILED"
fi
exit "$rc"

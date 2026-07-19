#!/bin/bash
# keepalived track_script: fail (demoting the master) when the WAN link is
# not up. Only enforced while master - the backup's WAN is administratively
# down by design, so it must not be penalized.

STATE_FILE=/run/ha-router/state

[ "$(cat "$STATE_FILE" 2>/dev/null)" = "master" ] || exit 0

# Grace period: right after a takeover the link needs a few seconds to come
# up and autonegotiate. Don't enforce carrier until the transition settles,
# or every failover starts with spurious failures (and, with two nodes, a
# -60 priority wobble that can ping-pong mastership).
now=$(date +%s)
transitioned=$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)
[ $((now - transitioned)) -lt 30 ] && exit 0

# operstate (unlike carrier) reads "down" instead of EINVAL on an
# admin-down interface, so a failure here is quiet and unambiguous.
[ "$(cat /sys/class/net/end0/operstate 2>/dev/null)" = "up" ]

#!/bin/bash
# keepalived track_script: fail (demoting the master) when the WAN link has
# no carrier. Only enforced while master - the backup's WAN is
# administratively down by design, so it must not be penalized.

STATE="$(cat /run/ha-router/state 2>/dev/null)"
[ "$STATE" = "master" ] || exit 0

[ "$(cat /sys/class/net/end0/carrier 2>/dev/null)" = "1" ]

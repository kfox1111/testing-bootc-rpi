# Architecture Design Document: High Availability Home NAT

## 1. Executive Summary & Objective
To build a highly available (HA), multi-node home NAT router cluster on enterprise-grade RHEL 10 or derivative that achieves near-instantaneous failover (<1 second) without dropping existing TCP stateful connections (SSH, streaming, VPNs).

The critical challenge is navigating an aggressive upstream ISP DHCP server that enforces rate-limiting/cooldown blocks on client requests, while operating under a strict single public IPv4 address constraint.

---

## 2. Core Architectural Decisions

### Decision 1: Use keepalived + conntrackd (FTFW Mode)
* **Rationale:** Floating a Layer 3 Virtual IP (VIP) via keepalived is not enough for stateful NAT. If Node 2 assumes the VIP without knowing the active connection table, mid-stream packets trigger a TCP RST, dropping all connections.
* **Implementation:** conntrackd runs in Fault-Tolerant FireWall (FTFW) mode over a dedicated private heartbeat link (enu1u1). It continuously syncs the Linux kernel's connection tracking (nf_conntrack) tables from Master to Backup via unicast UDP.

### Decision 2: Bypass NetworkManager via dhcpcd for WAN
* **Rationale:** RHEL 10's native NetworkManager internal DHCP client lacks a purely passive lease-playback mechanism; it enforces a unicast DHCPREQUEST on link-up, which triggers the ISP's rate limiter and breaks failover.
* **Implementation:** The WAN interface (end0) is explicitly declared as unmanaged in NetworkManager. The standalone dhcpcd binary (sourced via EPEL) manages the WAN interface independently, allowing complete control over the DHCP state machine. dhcpcd is configured with `lastleaseextend` so the saved lease is used even when the ISP's DHCP server refuses to answer.

### Decision 3: Identity Cloning (Zero-DHCP Failover)
* **Rationale:** The ISP limits the deployment to a single public IP lease.
* **Implementation:** Both nodes act as an exact hardware clone. They share the same WAN MAC address (a locally administered address, set by the keepalived notify script on takeover) and explicit DHCP Client ID (DUID, synced as part of /var/lib/dhcpcd). Node 2 keeps its WAN link administratively DOWN while in a backup state to eliminate MAC/IP collisions on the upstream switch.

### Decision 4: Event-Driven State Replication via dhcpcd Hooks
* **Rationale:** Standard time-based synchronization (e.g., cron) introduces a risky "blind spot" window where the primary lease could update or renew just before a master node crash, leaving the backup node with stale lease data.
* **Implementation:** Synchronization is entirely event-driven. A dhcpcd exit-hook (`/etc/dhcpcd.exit-hook`) triggers an immediate rsync transaction the moment a lease is bound, renewed, or allocated.

### Decision 5: Should be cheap to implement.
* **Rationale:** It should be cheap for anyone to implement and cheap to get replacement parts.
* **Implementation:** Get a couple of Raspberry Pi 5's. They are hardy enough for 1Gb ethernet and have m.2 real SSDs for preemptive failure monitoring.

### Decision 6: Should be image based
* **Rationale:** Build an image one time, distribute the exact image to both instances for better reliability.
* **Implementation:** Use bootc images for easy management of the images. Both nodes boot the identical image; everything node-specific lives in the machine-local /etc (see section 6) and is generated once by the `ha-node-setup` tool shipped in the image.

### Decision 7: nftables based
* **Rationale:** It seems best fit for the conntrackd backed firewall failover.
* **Implementation:** Use nftables over iptables or firewalld. firewalld is masked. The full NAT ruleset (input/forward filtering + masquerade) lives in `/etc/nftables/router.nft`, loaded via an include in `/etc/sysconfig/nftables.conf` (the file `nftables.service` actually reads on RHEL-family systems).

### Decision 8: WAN failure must demote the master
* **Rationale:** VRRP alone only detects node death. A master with a dead WAN cable would otherwise keep the VIP while routing nothing.
* **Implementation:** A keepalived `track_script` (`check-wan.sh`) fails when end0 loses carrier while the node is master, dropping its priority (150 - 60 = 90) below the backup's (100) and triggering failover. The check is a no-op on the backup, whose WAN is administratively down by design.

---

## 3. High-Level Component Layout

```text
                  [ ISP Modem / Bridge Mode ]
                               |
                       [ Unmanaged Switch ]
                        /              \
             (end0: Shared MAC)    (end0: Shared MAC)
                 +-------+              +-------+
                 | Node1 |--------------| Node2 |  <-- Dedicated Heartbeat (enu1u1)
                 | Active|   State Sync | Backup|      (conntrackd + hook rsync)
                 +-------+              +-------+      (10.0.0.1 <-> 10.0.0.2 /30)
             (enu1u2: 192.168.1.2)  (enu1u2: 192.168.1.3)
                        \              /
                    (LAN VIP: 192.168.1.1)
                               |
                       [ Home LAN Switch ]
```

## 4. Technical Configuration & State Orchestration

### 4.1 Event-Driven Lease Sync (dhcpcd Hook)
`/etc/dhcpcd.exit-hook` (shipped in the image) mirrors the lease database to the backup node on every state transition:

* On `BOUND|RENEW|REBIND|REBOOT` for end0, it rsyncs `/var/lib/dhcpcd/` (lease + DUID) to `root@$PEER_HB_IP` over the heartbeat link (ssh, BatchMode, backgrounded so dhcpcd never blocks on a dead peer).
* On `BOUND|REBOOT` it additionally fires gratuitous ARP on end0 so the ISP modem's ARP/CAM tables move to this node's port immediately after a takeover.
* The peer address comes from `/etc/ha-router/node.env`; the hook is inert until `ha-node-setup` has been run.

### 4.2 Keepalived State Transitions
keepalived (VRRPv3, `advert_int 0.3` for sub-second detection, unicast between the two LAN addresses) drives `/usr/libexec/keepalived/notify.sh`, which orchestrates the following sequences:

#### On Failover to Backup (Backup -> Master):
1. **Clone Link Layer:** Force end0's hardware address to the shared MAC from node.env and bring the link up.
2. **Instant Lease Playback (zero upstream packets):** the dhcpcd exit-hook captured the lease essentials (IP, prefix, gateway) into `/var/lib/dhcpcd/ha-lease.env` at bind time, and rsync carried it to this node; the notify script sources it and injects the IP, prefix, and default route with `ip addr replace` / `ip route replace`, then fires gratuitous ARP. WAN forwarding is restored in milliseconds without any DHCP exchange, so takeover speed never depends on the ISP's rate-limited DHCP server. (Note: `dhcpcd -U` cannot be used for this — dhcpcd 10 only answers it from a running daemon.)
3. **Background Lease Confirmation:** dhcpcd is then started normally. It sends one INIT-REBOOT DHCPREQUEST for the same lease from the same MAC/DUID — indistinguishable from a routine renewal, so it does not trip new-lease rate limiting. If the server ACKs, dhcpcd owns renewals from there (it takes over the address/route seamlessly, including a few seconds of ARP probing first — traffic keeps flowing on the played-back address throughout); if the server stays silent, `lastleaseextend` keeps the replayed lease; if it NAKs, dhcpcd correctly re-DISCOVERs.
4. **Commit Conntrack Table:** `conntrackd -c` flushes the synchronized userspace connection cache into the live Netfilter kernel space (followed by `-f` internal flush and `-R` resync — the standard primary-backup sequence).
5. **LAN GARP:** keepalived itself sends gratuitous ARP for the LAN VIP.

#### On Master -> Backup/Fault/Stop:
1. **Graceful Daemon Exit:** `dhcpcd -x end0` stops the daemon WITHOUT sending a DHCP_RELEASE upstream, keeping the lease valid for the peer.
2. **Flush Interface:** `ip addr flush dev end0` and `ip link set dev end0 down` so the node cleanly relinquishes the shared identity off the wire.
3. **Resync:** `conntrackd -n` requests a fresh copy of the connection table from the new master.

#### Planned Maintenance (e.g., kernel/bootc update) is seamless:
Simply reboot the master. On shutdown, keepalived sends a priority-0 VRRP advertisement, so the backup takes over within one advert interval (~0.3s) instead of waiting for timeouts; the notify_stop hook releases the WAN identity cleanly; the new master replays the lease offline. Combined with the pre-synced conntrack table, established TCP flows see at most a sub-second stall and no resets. This seamlessness relies on: (a) `/var/lib/dhcpcd` being in sync (check the `dhcpcd-hook` syslog tag), (b) conntrackd running on both nodes, (c) the shared MAC/DUID configuration from `ha-node-setup`.

---

## 5. Verification & Maintenance Notes

* **Automated smoke test:** `containers/internet/smoke-test.sh` (requires podman) builds the image against a stand-in AlmaLinux 10 bootc base and runs 22 assertions in a privileged container: config rendering/validation, nftables ruleset load, and the full failover lifecycle against a real DHCP server (dnsmasq) — cold lease acquisition + hook capture, clean demotion, sub-second warm takeover via offline lease playback, and background lease re-confirmation. Run it after any change to the files in this directory.
* **Lease Renewal Behavior:** When dhcpcd's internal timer hits the standard T1 renewal threshold (typically 50% of lease duration), it performs a standard renewal handshake. Because this occurs long after the failover, it safely bypasses the ISP's immediate rate-limiting window.
* **Bidirectional Safety:** Because the dhcpcd daemon is entirely stopped on the backup node, the synchronization hook remains inert on the passive node, eliminating any potential split-brain or reverse-sync loop hazards.
* **NetworkManager Override Prevention:** `/etc/NetworkManager/conf.d/99-unmanage-wan.conf` (baked into the image) must contain:
    ```ini
    [keyfile]
    unmanaged-devices=interface-name:end0;interface-name:wlan0
    ```
* **On-hardware failover test:** with an SSH session and a streaming download running through the router: (a) planned — `reboot` the master; expect a near-zero blip. (b) crash — pull the master's power; expect <1s stall. Both cases: no TCP resets, and no DHCPDISCOVER visible upstream (verify with tcpdump on the ISP-side switch mirror if available).

## 6. Interfaces

| Interface | Role | Addressing |
|-----------|------|------------|
| end0 (onboard NIC) | WAN (ISP-facing) | ISP DHCP lease, shared MAC + DUID, dhcpcd-managed, down on backup |
| enu1u1 (USB NIC 1) | Heartbeat: conntrackd sync + lease rsync | 10.0.0.1 (node1) / 10.0.0.2 (node2), /30, static |
| enu1u2 (USB NIC 2) | Internal LAN + VRRP | 192.168.1.2 (node1) / 192.168.1.3 (node2), /24, VIP 192.168.1.1 |
| wlan0 | Disabled (NM-unmanaged, wpa_supplicant masked) | — |

USB NIC names (`enu1u1`/`enu1u2`) are derived from the physical USB port — always keep each adapter plugged into the same port, or the heartbeat and LAN roles will swap.

## 7. Operational Details

### 7.1 What lives where
Shipped in the bootc image (identical on both nodes, replaced on upgrade):

| Path | Purpose |
|------|---------|
| /etc/dhcpcd.conf | WAN dhcpcd config (`lastleaseextend`, fast timeouts) |
| /etc/dhcpcd.exit-hook | lease sync + WAN GARP hook |
| /etc/nftables/router.nft | NAT/firewall ruleset (+ include line in /etc/sysconfig/nftables.conf) |
| /usr/share/ha-router/*.tmpl | keepalived/conntrackd templates |
| /usr/libexec/keepalived/notify.sh | keepalived state-transition orchestrator |
| /usr/libexec/keepalived/check-wan.sh | WAN carrier track_script |
| /usr/bin/ha-node-setup | per-node setup tool |
| /etc/sysctl.d/99-nat-router.conf | ip_forward, nonlocal_bind, nf_conntrack_tcp_be_liberal |

Machine-local in /etc (generated by `ha-node-setup`, survives bootc upgrades via ostree's /etc merge):

| Path | Purpose |
|------|---------|
| /etc/ha-router/node.env | NODE_ID, PRIORITY, HB_IP, PEER_HB_IP, LAN_IP, LAN_VIP, WAN_MAC |
| /etc/keepalived/keepalived.conf | rendered from template |
| /etc/conntrackd/conntrackd.conf | rendered from template |
| /etc/NetworkManager/system-connections/ha-*.nmconnection | static heartbeat + LAN profiles |
| /root/.ssh/id_ed25519(.pub), authorized_keys | rsync lease-sync trust |
| /var/lib/dhcpcd/ | lease + DUID (rsync-synced master -> backup) |

### 7.2 Bring-up runbook
1. Flash/install the same bootc image on both Pis; cable end0 to the ISP switch, enu1u1 node-to-node, enu1u2 to the LAN switch.
2. `node1# ha-node-setup --node 1` — prints node1's public key.
3. `node2# ha-node-setup --node 2 --authorize-key '<node1 pubkey>'` — prints node2's public key.
4. `node1# ha-node-setup --node 1 --authorize-key '<node2 pubkey>'` (idempotent re-run).
5. Verify: `cat /run/ha-router/state` (one master, one backup), `conntrackd -s` (sync counters moving), `cat /var/lib/dhcpcd/ha-lease.env` on the backup (synced lease present after the first bind/renewal), `nft list ruleset`, `journalctl -t dhcpcd-hook -t ha-router`.

### 7.3 Common operations
* **Force a switchover:** `systemctl stop keepalived` on the master (start it again to preempt back — node1 has the higher priority, so it retakes master when healthy). Stopping keepalived releases the WAN via notify_stop (dhcpcd stopped without RELEASE, address flushed, end0 down) — if end0 stays up after a stop, the notify script is being blocked (this was the observed symptom of SELinux enforcing; see 7.4).
* **Update both nodes:** `bootc upgrade` + reboot the backup first, verify it rejoins, then reboot the master (seamless per section 4.2).
* **Check lease sync is flowing:** `journalctl -t dhcpcd-hook` on the master should log a sync on every BOUND/RENEW.
* **Recovering node returns:** it boots as backup (WAN down), conntrackd resyncs, then preemption may promote it if it has the higher priority — this switchover is as seamless as a planned one.

### 7.4 Known constraints & cautions
* **Never bring end0 up manually on the backup** — two live ports with the same MAC will make the upstream switch flap and can poison the single lease.
* The design assumes the ISP rate-limits *new* lease requests (DISCOVER); same-identity INIT-REBOOT/renewals are assumed safe. If the ISP blocks even those, `lastleaseextend` still keeps the WAN up on the replayed lease until T1 renewal eventually succeeds.
* **SELinux (found the hard way on first hardware bring-up):** keepalived runs notify/track scripts in the confined `keepalived_t` domain — `logger` works but interface management and spawning dhcpcd are denied, so the master transition silently half-completes (link stays down, no dhcpcd, and the stop path can't release the WAN either). Two mitigations are in place:
    1. The scripts live in `/usr/libexec/keepalived/`, which the policy labels `keepalived_unconfined_script_exec_t` so they (and the dhcpcd they spawn, and its exit-hook's rsync) run unconfined. Do not move them — anywhere else they are labeled `bin_t` and stay confined.
    2. The image currently defaults to **SELinux permissive** (`/etc/selinux/config`, set in the Dockerfile) while the system burns in. Permissive still logs every would-be denial. Follow-up task: after burn-in, harvest the log (`ausearch -m avc | audit2allow -M ha-router`), install the local module, and set `SELINUX=enforcing` again. Note `/etc/selinux/config` is machine-local under bootc — a node whose /etc was modified by hand keeps its own setting across image updates.
* LAN DHCP/DNS service for clients is **out of scope** of this design — nothing here answers DHCP on 192.168.1.0/24. Decide separately (e.g., kea or dnsmasq, ideally HA-aware).
* IPv6 on the WAN is out of scope (`ipv4only`/`noipv6rs` in dhcpcd.conf); the single-lease identity trick is IPv4-specific.

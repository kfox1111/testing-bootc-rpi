ARG BASE=test

FROM $BASE

RUN dnf install -y epel-release && \
    dnf install -y \
      keepalived \
      conntrack-tools \
      dhcpcd \
      rsync \
      iproute \
      iputils \
      nftables \
      openssh-clients \
      nmap-ncat && \
    dnf clean all

# Router sysctls: forward IPv4, allow binding the VIP before it exists, and
# accept mid-stream TCP packets when taking over a synced conntrack table.
# nf_conntrack must be loaded at boot for the netfilter sysctl to apply.
RUN printf '%s\n' \
      "net.ipv4.ip_forward = 1" \
      "net.ipv4.ip_nonlocal_bind = 1" \
      "net.netfilter.nf_conntrack_tcp_be_liberal = 1" \
      > /etc/sysctl.d/99-nat-router.conf && \
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

# The WAN interface (end0) is owned by dhcpcd, driven by keepalived - never
# NetworkManager. wlan0 is unused in this design (DESIGN.md section 6).
RUN mkdir -p /etc/NetworkManager/conf.d/ && \
    printf '[keyfile]\nunmanaged-devices=interface-name:end0;interface-name:wlan0\n' \
      > /etc/NetworkManager/conf.d/99-unmanage-wan.conf && \
    systemctl mask wpa_supplicant.service

# TEMPORARY: run SELinux permissive while the system burns in. Everything
# works, every would-be denial is still logged (ausearch -m avc), and once
# the router is proven the accumulated log becomes the input for a local
# policy module + SELINUX=enforcing again. See DESIGN.md section 7.4.
RUN sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

COPY dhcpcd.conf /etc/dhcpcd.conf
COPY dhcpcd.exit-hook /etc/dhcpcd.exit-hook
COPY router.nft /etc/nftables/router.nft
COPY keepalived.conf.tmpl conntrackd.conf.tmpl /usr/share/ha-router/
# Scripts keepalived executes MUST live in /usr/libexec/keepalived: the
# SELinux policy labels that path keepalived_unconfined_script_exec_t so
# they (and the dhcpcd they spawn) run unconfined. Anywhere else they stay
# confined in keepalived_t, which cannot manage interfaces or start dhcpcd.
COPY notify.sh check-wan.sh /usr/libexec/keepalived/
COPY ha-node-setup /usr/bin/ha-node-setup

RUN chmod 0755 /usr/libexec/keepalived/notify.sh \
               /usr/libexec/keepalived/check-wan.sh \
               /usr/bin/ha-node-setup && \
    chmod 0644 /etc/dhcpcd.exit-hook && \
    echo 'include "/etc/nftables/router.nft"' >> /etc/sysconfig/nftables.conf

# firewalld would fight the nftables ruleset. dhcpcd must NOT autostart: its
# lifecycle is owned by the keepalived notify script, and the WAN stays down
# until VRRP elects this node master.
RUN systemctl disable firewalld.service && \
    systemctl mask firewalld.service && \
    systemctl enable nftables.service keepalived.service conntrackd.service && \
    (systemctl disable dhcpcd.service 2>/dev/null || true)

FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10

RUN dnf install -y epel-release && \
    dnf install -y \
      keepalived \
      conntrack-tools \
      dhcpcd \
      rsync \
      iproute \
      nftables \
      nmap-ncat && \
    dnf clean all

RUN echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-nat-router.conf && \
    echo "net.ipv4.ip_nonlocal_bind = 1" >> /etc/sysctl.d/99-nat-router.conf

RUN mkdir -p /etc/NetworkManager/conf.d/ && \
    echo -e "[keyfile]\nunmanaged-devices=interface-name:eth0" > /etc/NetworkManager/conf.d/99-unmanage-wan.conf

RUN mkdir -p /usr/libexec/dhcpcd-hooks/

RUN systemctl disable firewalld.service && \
    systemctl mask firewalld.service

RUN systemctl enable nftables.service

RUN echo 'table inet filter { chain input { type filter hook input priority 0; policy accept; } chain forward { type filter hook forward priority 0; policy drop; ct state established,related accept; } chain output { type filter hook output priority 0; policy accept; } }' > /etc/nftables.conf


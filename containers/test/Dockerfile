FROM quay.io/almalinuxorg/almalinux:10

RUN \
  dnf install -y git rpm-build patch make gcc && \
  cd /tmp && \
  git clone https://git.almalinux.org/rpms/raspberrypi2.git && \
  cd raspberrypi2 && \
  git checkout a10 && \
  cd SPECS && \
  rpmbuild  -bp raspberrypi2.spec && \
  pwd && \
  ls -l

RUN exit 1
FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10

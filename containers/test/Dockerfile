FROM quay.io/almalinuxorg/almalinux:10

COPY mac.patch /tmp/mac.patch
COPY spec.patch /tmp/spec.patch

RUN \
  set -x && \
  dnf install -y git rpm-build patch make gcc dnf-plugins-core rpmdevtools && \
  cd /tmp && \
  git clone https://git.almalinux.org/rpms/raspberrypi2.git && \
  cd raspberrypi2 && \
  git checkout a10 && \
  cd SPECS && \
  dnf builddep -y raspberrypi2.spec && \
  spectool -g -R  raspberrypi2.spec && \
  mkdir -p ~/rpmbuild/SOURCES && \
  cp -f -a ../SOURCES/* ~/rpmbuild/SOURCES/ && \
  cp /tmp/mac.patch ~/rpmbuild/SOURCES/ && \
  patch -p0 < /tmp/spec.patch && \
  rpmbuild  -ba raspberrypi2.spec

RUN exit 1
#FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10

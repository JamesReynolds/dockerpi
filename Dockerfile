# Build stage for qemu-system-arm
FROM debian:stable-slim AS qemu-system-arm-builder
ARG QEMU_VERSION=4.2.0
ENV QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
WORKDIR /qemu

RUN # Update package lists
RUN apt-get update

RUN # Pull source
RUN apt-get -y install wget
RUN wget "https://download.qemu.org/${QEMU_TARBALL}"

RUN # Verify signatures
RUN apt-get -y install gpg
RUN wget "https://download.qemu.org/${QEMU_TARBALL}.sig"
RUN gpg --keyserver keyserver.ubuntu.com --recv-keys CEACC9E15534EBABB82D3FA03353C9CEF108B584
RUN gpg --verify "${QEMU_TARBALL}.sig" "${QEMU_TARBALL}"

RUN # Extract source tarball
RUN apt-get -y install pkg-config
RUN tar xvf "${QEMU_TARBALL}"

RUN # Build source
# These seem to be the only deps actually required for a successful  build
RUN apt-get -y install python build-essential libglib2.0-dev libpixman-1-dev
# These don't seem to be required but are specified here: https://wiki.qemu.org/Hosts/Linux
RUN apt-get -y install libfdt-dev zlib1g-dev
# Not required or specified anywhere but supress build warnings
RUN apt-get -y install flex bison
RUN "qemu-${QEMU_VERSION}/configure" --static --target-list=arm-softmmu,aarch64-softmmu
RUN make -j$(nproc)

RUN # Strip the binary, this gives a substantial size reduction!
RUN strip "arm-softmmu/qemu-system-arm" "aarch64-softmmu/qemu-system-aarch64"


# Build stage for Serial-TUN
FROM debian:stable-slim AS serialtun-builder
WORKDIR /serial_tun

RUN # Update package lists
RUN apt-get update

RUN # Pull source
RUN apt-get -y install wget git
RUN git clone https://github.com/sakisds/Serial-TUN.git

RUN # Build source
RUN sed -i s#/.*libserialport.so#/usr/lib/x86_64-linux-gnu/libserialport.a#g Serial-TUN/CMakeLists.txt
RUN apt-get -y install build-essential cmake libserialport-dev libserialport0
RUN cmake "Serial-TUN" -DCMAKE_C_COMPILER_ARG1='-static'
RUN make -j$(nproc)
RUN find / -name serial_tun


# Build stage for fatcat
FROM debian:stable-slim AS fatcat-builder
ARG FATCAT_VERSION=1.1.0
ENV FATCAT_TARBALL="v${FATCAT_VERSION}.tar.gz"
WORKDIR /fatcat

RUN # Update package lists
RUN apt-get update

RUN # Pull source
RUN apt-get -y install wget
RUN wget "https://github.com/Gregwar/fatcat/archive/${FATCAT_TARBALL}"

RUN # Extract source tarball
RUN tar xvf "${FATCAT_TARBALL}"

RUN # Build source
RUN apt-get -y install build-essential cmake
RUN cmake "fatcat-${FATCAT_VERSION}" -DCMAKE_CXX_FLAGS='-static'
RUN make -j$(nproc)


# Build the dockerpi VM image
FROM busybox:1.31 AS dockerpi-vm
LABEL maintainer="Luke Childs <lukechilds123@gmail.com>"
ARG RPI_KERNEL_URL="https://github.com/dhruvvyas90/qemu-rpi-kernel/archive/afe411f2c9b04730bcc6b2168cdc9adca224227c.zip"
ARG RPI_KERNEL_CHECKSUM="295a22f1cd49ab51b9e7192103ee7c917624b063cc5ca2e11434164638aad5f4"

COPY --from=qemu-system-arm-builder /qemu/arm-softmmu/qemu-system-arm /usr/local/bin/qemu-system-arm
COPY --from=qemu-system-arm-builder /qemu/aarch64-softmmu/qemu-system-aarch64 /usr/local/bin/qemu-system-aarch64
COPY --from=fatcat-builder /fatcat/fatcat /usr/local/bin/fatcat
COPY --from=serialtun-builder /serial_tun/serial_tun /usr/local/bin/serial_tun

ADD $RPI_KERNEL_URL /tmp/qemu-rpi-kernel.zip

RUN cd /tmp && \
    echo "$RPI_KERNEL_CHECKSUM  qemu-rpi-kernel.zip" | sha256sum -c && \
    unzip qemu-rpi-kernel.zip && \
    mkdir -p /root/qemu-rpi-kernel && \
    cp qemu-rpi-kernel-*/kernel-qemu-4.19.50-buster /root/qemu-rpi-kernel/ && \
    cp qemu-rpi-kernel-*/versatile-pb.dtb /root/qemu-rpi-kernel/ && \
    rm -rf /tmp/*

VOLUME /sdcard

ADD ./entrypoint.sh /entrypoint.sh
#ENTRYPOINT ["./entrypoint.sh"]



# Build the dockerpi image
# It's just the VM image with a compressed Raspbian filesystem added
FROM dockerpi-vm as dockerpi
LABEL maintainer="Luke Childs <lukechilds123@gmail.com>"
ARG FILESYSTEM_IMAGE_URL="http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-09-30/2019-09-26-raspbian-buster-lite.zip"
ARG FILESYSTEM_IMAGE_CHECKSUM="a50237c2f718bd8d806b96df5b9d2174ce8b789eda1f03434ed2213bbca6c6ff"

ADD $FILESYSTEM_IMAGE_URL /filesystem.zip

RUN echo "$FILESYSTEM_IMAGE_CHECKSUM  /filesystem.zip" | sha256sum -c

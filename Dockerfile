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
RUN git clone https://github.com/jamesreynolds/Serial-TUN.git

RUN # Build source for x86
RUN apt-get install -y software-properties-common make curl gcc ncurses-dev perl git automake libtool
RUN add-apt-repository ppa:linaro-maintainers/toolchain
RUN apt-get -y install build-essential cmake libserialport-dev libserialport0 pkg-config gcc-arm-linux-gnueabi
RUN mkdir build_x86_64 && cd build_x86_64 && cmake ../Serial-TUN && make -j$(nproc)

RUN # Build source for arm
RUN git clone git://sigrok.org/libserialport
RUN cd libserialport \
	&& ./autogen.sh \
	&& CC=/usr/bin/arm-linux-gnueabi-gcc ./configure --host x86_64-pc-linux-gnu --target=arm-linux-gnueabi \
	&& make -j $(nproc) \
	&& cp .libs/libserialport.a /usr/arm-linux-gnueabi/lib
RUN mkdir build_arm && cd build_arm && cmake ../Serial-TUN -DCMAKE_C_COMPILER=/usr/bin/arm-linux-gnueabi-gcc && make -j$(nproc)

RUN mkdir proto
ADD tun.sh proto/
RUN cp /serial_tun/build_arm/serial_tun proto
RUN truncate -s $(( 10 * 1024 * 1024 )) card.img
RUN mkfs.ext4 -d proto card.img

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


# Build stage for dtc
FROM debian:stable-slim AS dtc-builder
ARG DTC_VERSION=1.5.1
ENV DTC_TARBALL="v${DTC_VERSION}.tar.gz"
WORKDIR /dtc

RUN # Update package lists
RUN apt-get update

RUN # Pull source
RUN apt-get -y install wget
RUN wget https://github.com/dgibson/dtc/archive/${DTC_TARBALL}

RUN # Extract source tarball
RUN tar xvf "${DTC_TARBALL}"

RUN # Build source (slightly hacky to make a statically compiled dtc)
RUN apt-get -y install build-essential cmake flex pkg-config bison
RUN cd dtc-${DTC_VERSION} && gcc -o ../dtc $(make dtc | grep CC | sed 's/.* \(.*\).o/\1.c/g') -DNO_YAML -static -I libfdt

# Build the dockerpi VM image
FROM busybox:1.31 AS dockerpi-vm
LABEL maintainer="Luke Childs <lukechilds123@gmail.com>"
ARG RPI_KERNEL_URL="https://github.com/dhruvvyas90/qemu-rpi-kernel/archive/afe411f2c9b04730bcc6b2168cdc9adca224227c.zip"
ARG RPI_KERNEL_CHECKSUM="295a22f1cd49ab51b9e7192103ee7c917624b063cc5ca2e11434164638aad5f4"

COPY --from=qemu-system-arm-builder /qemu/arm-softmmu/qemu-system-arm /usr/local/bin/qemu-system-arm
COPY --from=qemu-system-arm-builder /qemu/aarch64-softmmu/qemu-system-aarch64 /usr/local/bin/qemu-system-aarch64
COPY --from=fatcat-builder /fatcat/fatcat /usr/local/bin/fatcat
COPY --from=serialtun-builder /serial_tun/build_x86_64/pipe_tun /usr/local/bin/pipe_tun
COPY --from=serialtun-builder /serial_tun/card.img /usr/local/card.img
COPY --from=dtc-builder /dtc/dtc /usr/local/bin/dtc

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

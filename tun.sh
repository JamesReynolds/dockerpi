#!/bin/sh -eu

"$(dirname "$0")"/serial_tun -i tun0 -p /dev/ttyS1 &
ip link set tun0 up
ip addr add 10.10.10.1/24 dev tun

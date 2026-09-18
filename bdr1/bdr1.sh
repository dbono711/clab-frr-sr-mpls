#!/bin/bash

# create logs directory
mkdir -p /etc/frr/logs
chown -R frr:frr /etc/frr/logs
chmod 775 /etc/frr/logs

# delete default route
ip route del default

# Enable MPLS input processing on core-facing interfaces; resets to 0 on every boot
sysctl -w net.mpls.conf.eth1.input=1
sysctl -w net.mpls.conf.lo.input=1
sysctl -w net.mpls.platform_labels=1048575

# create internet loopback interface
ip link add internet0 type dummy
ip link set internet0 up

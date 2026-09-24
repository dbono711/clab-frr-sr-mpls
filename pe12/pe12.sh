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

# RED
## create VLAN interface for RED service
ip link add name eth3.10 link eth3 type vlan id 10
ip link set dev eth3.10 up

## create RED VRF and attach the VLAN interface to it
ip link add dev RED type vrf table 10
ip link set dev RED up
ip link set dev eth3.10 master RED

# BLUE
## create VLAN interface for BLUE service
ip link add name eth3.20 link eth3 type vlan id 20
ip link set dev eth3.20 up

## create BLUE VRF and attach the VLAN interface to it
ip link add dev BLUE type vrf table 20
ip link set dev BLUE up
ip link set dev eth3.20 master BLUE

# The Linux kernel resets net.vrf.strict_mode to 0 whenever a
# new VRF is created or the system restarts, which prevents FRR
# from installing VRF routes correctly
sysctl -w net.vrf.strict_mode=1

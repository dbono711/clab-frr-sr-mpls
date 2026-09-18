# clab-frr-sr-mpls

## Overview

A Segment Routing MPLS (SR-MPLS) network using [CONTAINERlab](https://containerlab.dev/) and [FRRouting (FRR)](https://frrouting.org/) nodes to demonstrate [SR-MPLS](https://docs.frrouting.org/en/latest/isisd.html#segment-routing) capabilities in a controlled lab environment.

This lab provides a practical environment for learning and testing core SR-MPLS concepts including the SRGB, IS-IS Prefix-SIDs, SR-MPLS transport for (IPv4 + IPv6) BGP L3VPN services, BGP Labeled-Unicast (RFC 3107) for global-table transport, and native FRR `pathd` Segment Routing Traffic Engineering (SR-TE) policies.

## Requirements

- [CONTAINERlab](https://containerlab.dev/install/)
  - _The [CONTAINERlab](https://containerlab.dev/install/) installation guide outlines various installation methods. This lab assumes all [pre-requisites](https://containerlab.dev/install/#pre-requisites) (including Docker) are met and CONTAINERlab is installed via the [install script](https://containerlab.dev/install/#install-script)._
- Docker FRR image: `quay.io/frrouting/frr:10.7.1` (will be downloaded automatically)
- Docker Network Multitool image: `wbitt/network-multitool:alpine-extra` (for client nodes) (will be downloaded automatically)
- **Host MPLS kernel modules**: containers here share the host kernel's MPLS dataplane, so the host must load the MPLS modules before deploying:

  ```shell
  sudo modprobe mpls_router mpls_iptunnel mpls_gso
  ```

  `make lab` runs this automatically; if you deploy directly with `clab deploy` instead of `make lab`, run it yourself first.

## Topology

![Lab topology](images/topology.png)

## Network Resources

- Loopback addresses double as router IDs (BGP, IS-IS), allocated from the `172.16.0.0/24` block and follow the format `172.16.0.y/32`, where `y` is assigned incrementally per device.
- All routers are part of IS-IS Level 2 with IS-IS NET addresses derived directly from the router ID, using the format `49.0001.xxxx.xxxx.xxxx.00` (e.g., `49.0001.1721.6000.0001.00` for pe1). Essentially: zero-pad each router-ID octet to 3 digits, concatenate them, regroup the resulting 12 digits as 4+4+4, and wrap with the `49.0001.` prefix and `.00` suffix.
- BGP is configured on the PEs (pe1, pe2, bdr1) and the route reflector (rr) with ASN 65000.
- `pe1`, `pe2`, and `rr` each carry an extra `ipv6 address ::ffff:172.16.0.y/128` on `lo` alongside the IPv4 loopback — an IPv4-mapped IPv6 address, not advertised into ISIS. Two independent reasons it has to look exactly like this: (1) FRR refuses to negotiate `address-family ipv6 vpn` (needed for the BLUE/RED VRFs' IPv6 side) with **zero** local IPv6 addresses present anywhere on the router, failing the *entire* session (`Cease/Unspecific`) rather than just that AF; and (2) the same address becomes the actual vpnv6 `next-hop-self` value advertised to peers, and only the IPv4-mapped form is resolvable by zebra (via the embedded IPv4 address, matched against the IPv4 RIB) — a native/arbitrary IPv6 address here is a valid-looking BGP path that can never be installed, since there's no real IPv6 anywhere in this underlay to resolve it against. `bdr1` never activates `ipv6 vpn`, so it doesn't need one.

| Node | Loopback / Router ID | IS-IS NET | Prefix-SID Index | Label |
|---|---|---|---|---|
| pe1  | 172.16.0.1/32  | 49.0001.1721.6000.0001.00 | 101 | 16101 |
| p1   | 172.16.0.2/32  | 49.0001.1721.6000.0002.00 | 102 | 16102 |
| p2   | 172.16.0.3/32  | 49.0001.1721.6000.0003.00 | 103 | 16103 |
| p3   | 172.16.0.4/32  | 49.0001.1721.6000.0004.00 | 104 | 16104 |
| p4   | 172.16.0.5/32  | 49.0001.1721.6000.0005.00 | 105 | 16105 |
| pe2  | 172.16.0.6/32  | 49.0001.1721.6000.0006.00 | 106 | 16106 |
| rr   | 172.16.0.8/32  | 49.0001.1721.6000.0008.00 | — (no SR dataplane role) | — |
| bdr1 | 172.16.0.15/32 | 49.0001.1721.6000.0015.00 | 115 | 16115 |

### Core (Underlay) Links

IPv4 transit links between core nodes, packed as sequential `/31`s (RFC 3021) all within the single `10.0.1.0/24` block:

| Link | Subnet | IS-IS Metric |
|---|---|---|
| pe1–p1  (eth1/eth1) | 10.0.1.0/31  | default |
| p1–p2   (eth2/eth1) | 10.0.1.2/31  | default |
| p1–p3   (eth3/eth1) | 10.0.1.4/31  | default |
| p2–bdr1 (eth2/eth1) | 10.0.1.6/31  | default |
| p2–p4   (eth3/eth1) | 10.0.1.8/31  | default |
| p3–p4   (eth3/eth2) | 10.0.1.10/31 | **100** (both directions) |
| p4–pe2  (eth3/eth1) | 10.0.1.12/31 | default |
| p1–rr   (eth4/eth1) | 10.0.1.14/31 | default |

### Segment Routing Label Ranges

Kept disjoint to avoid collisions:

| Purpose | Range | Mechanism |
|---|---|---|
| SRGB (IS-IS Prefix-SID, identical on every SR node) | 16000–23999 | `segment-routing global-block 16000 23999` |
| pathd SR-TE binding-SIDs (static) | 30000–30099 | `binding-sid` under `policy color ...` |
| zebra dynamic label pool (BGP `label vpn export auto` / labeled-unicast) | 700000–799999 | `mpls label dynamic-block 700000 799999` |

`rr` runs IS-IS but has **no** `segment-routing on` and no Prefix-SID at all — it's a leaf off `p1`, never a transit hop or service next-hop, so it has no MPLS dataplane role.

### Client / VRF Prefixes

- **RED VRF**: pe1 `10.10.1.0/30` + `2001:c0de:10:1::/64`, pe2 `10.10.2.0/30` + `2001:c0de:10:2::/64`. RD `172.16.0.<pe>:10`, RT `65000:10`.
- **BLUE VRF**: pe1 `10.10.1.4/30` + `2001:c0de:10:3::/64`, pe2 `10.10.2.4/30` + `2001:c0de:10:4::/64`. RD `172.16.0.<pe>:20`, RT `65000:20`.
- **Global table**: pe1↔c3 `10.11.1.0/30`; bdr1's simulated Internet loopback `internet0` = `99.99.99.99/32`.

### Management Network

| Node | Management IP    |
|------|------------------|
| pe1  | 172.29.1.2/24    |
| pe2  | 172.29.1.3/24    |
| p1   | 172.29.1.4/24    |
| p2   | 172.29.1.5/24    |
| p3   | 172.29.1.6/24    |
| p4   | 172.29.1.7/24    |
| rr   | 172.29.1.8/24    |
| bdr1 | 172.29.1.15/24   |
| c1   | 172.29.1.9/24    |
| c2   | 172.29.1.10/24   |
| c3   | 172.29.1.11/24   |

## SR-MPLS-based L3VPN Services

This lab demonstrates SR-MPLS as the transport for L3VPN services, using IS-IS-distributed Prefix-SIDs as the underlay label-switched path to each PE's loopback:

- One SRGB, one Prefix-SID per node — no LDP, no RSVP-TE.
- L3VPN control plane is plain multiprotocol BGP (vpnv4 / vpnv6 address families) — same as classic BGP/MPLS L3VPN (RFC 4364).
- SR-MPLS just pushes/swaps/pops labels; the "service SID" is a normal MPLS VPN label.

### SR-MPLS Setup

- **SRGB**: every SR-capable node (pe1, pe2, p1–p4, bdr1) configures the identical `segment-routing global-block 16000 23999` under `router isis 1`, plus `segment-routing on` and `segment-routing node-msd 8`.
- **Prefix-SID**: each SR-capable node advertises its loopback with `segment-routing prefix <loopback>/32 index <N>` (see the table above for the index/label mapping — label = SRGB base + index).
- **No encapsulation-behavior required**: the underlay LSP toward a remote PE's loopback comes purely from IS-IS SR, and VPN traffic rides it via an ordinary imposed VPN label.

### BGP L3VPN Setup

- **VRF Configuration**: RED and BLUE VRFs are configured on both PE routers (pe1 and pe2) for the IPv4 and IPv6 unicast address families.
- **Client Connectivity**: c1 and c2 connect to pe1 and pe2 respectively through VLAN interfaces assigned to both VRFs — VLAN 10 for RED, VLAN 20 for BLUE.
- **Route Distinguishers and Route Targets**: RED uses `*:10` / `65000:10`, BLUE uses `*:20` / `65000:20`.
- **Per-AF Label Model**: `label vpn export auto` is configured inside **each** `address-family ipv4 unicast` / `ipv6 unicast` block (not at the vrf-instance level — FRR requires it nested under the AF, same as `rd vpn export`). FRR/zebra dynamically allocates one MPLS VPN label per AF per VRF (drawn from the `700000–799999` dynamic pool) — so RED gets two labels (one for its IPv4 side, one for IPv6).
- **End-to-End Service**: BGP L3VPN exchanges routes between matching VRFs on the PEs via the route reflector (`rr`), while the SR-MPLS underlay (IS-IS Prefix-SID LSPs) provides the data-plane transport across the core.

## Global Table: BGP Labeled-Unicast

- `pe1` originates the client3-connected subnet `10.11.1.0/30` under `address-family ipv4 unicast` with a plain `network` statement (no neighbor activation in that AF).
- `bdr1` originates the simulated Internet loopback `99.99.99.99/32` the same way.
- Both `pe1` and `bdr1` activate `address-family ipv4 labeled-unicast` toward `rr`, with `next-hop-self`.
- `rr` reflects the `ipv4 labeled-unicast` SAFI as a route-reflector-client — this SAFI **replaces** `rr`'s `ipv4 unicast` AF entirely, since FRR does not permit activating a peer for both `ipv4 unicast` and `ipv4 labeled-unicast` simultaneously (`BGP_ERR_PEER_SAFI_CONFLICT`).

The result: `c3 → pe1 → p1 → p2 → bdr1 → internet0` is fully label-switched end to end, **with no VRF anywhere in the path** — the prefixes never leave the default table. Verify with:

```shell
docker exec -it clab-frr-sr-mpls-c3 ping -c 5 99.99.99.99
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp ipv4 labeled-unicast"
docker exec -it clab-frr-sr-mpls-bdr1 vtysh -c "show mpls table"
```

## Manual SR-MPLS Traffic Steering (pathd)

The RED and BLUE services above rely on the BGP L3VPN overlay: the PEs learn each other's prefixes through the route reflector, FRR allocates the VPN label automatically, and the path across the core is whatever IS-IS SPF picks. This section shows the SR-MPLS way to override that — native FRR `pathd`, with explicit segment-lists, colored policies, and a binding-SID.

### The Policies

`pe1` is configured as the SR-TE headend with two colored policies toward `pe2` (`172.16.0.6`):

| Color | Binding-SID | Segment-List | Path | Why |
|---|---|---|---|---|
| 100 | 30000 | `SEG-VIA-P2` | p1 → p2 → p4 → pe2 | IGP-preferred (lower cost); mirrors plain ISIS SPF |
| 200 | 30001 | `SEG-VIA-P3` | p1 → p3 → p4 → pe2 | Manually forced alternate — p3–p4 carries the metric-100 bump, so SPF never picks this on its own |

Each segment-list is an explicit label stack of the transit nodes' Prefix-SID labels plus the endpoint's:

```text
segment-list SEG-VIA-P2: 16102 (p1), 16103 (p2), 16105 (p4), 16106 (pe2)
segment-list SEG-VIA-P3: 16102 (p1), 16104 (p3), 16105 (p4), 16106 (pe2)
```

`pe1` does not appear in its own segment-list — `pe1` is the node imposing the label stack, not a segment in it.

### Steering RED Traffic onto the Alternate Path

A route-map on `pe1`'s RED-VRF `ipv4 unicast` address family colors imported routes to force them onto the color-200 policy (`SEG-VIA-P3`), while BLUE and everything else continues to ride plain ISIS SPF (which picks `SEG-VIA-P2`'s path via `p2`, since `p3`–`p4` carries the metric-100 penalty):

```text
route-map STEER-RED-VIA-P3 permit 10
 set sr-te color 200
!
router bgp 65000 vrf RED
 address-family ipv4 unicast
  route-map vpn import STEER-RED-VIA-P3
 exit-address-family
```

**Risk flag**: coloring a VRF-imported BGP route into a `pathd` policy via `route-map ... vpn import ... set sr-te color` is a less commonly exercised combination than a plain SR-TE policy — it was authored based on FRR documentation but has not been validated live as of this writing. Both segment-lists and both policies are real, testable configuration regardless of whether the route-map steering resolves next-hops as expected. If it doesn't, fall back to a config-only demonstration:

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show sr-te policy"
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show mpls table"
```

### Watching It Happen

Because each policy pins a specific path, a before/after packet capture on `p2`'s vs. `p3`'s core-facing interface should show RED traffic disappear from `p2` and appear on `p3` once the steering route-map is applied:

```shell
sudo ip netns exec clab-frr-sr-mpls-p2 tcpdump -nni eth1 mpls
sudo ip netns exec clab-frr-sr-mpls-p3 tcpdump -nni eth1 mpls
```

```shell
docker exec -it clab-frr-sr-mpls-c1 ping -c 5 10.10.2.10
```

## Deployment

Clone this repository and start the lab:

```shell
git clone https://github.com/dbono711/clab-frr-sr-mpls.git
cd clab-frr-sr-mpls
sudo modprobe mpls_router mpls_iptunnel mpls_gso
sudo clab deploy -t lab.yml
```

**_NOTE: CONTAINERlab requires SUDO privileges in order to execute_**

The deployment process:

- Loads the host MPLS kernel modules (containers share the host kernel's MPLS dataplane)
- Creates the [CONTAINERlab network](lab.yml) based on the topology definition
- Applies the FRR configuration files from the respective router folders on each node
- Executes the initialization scripts for each router and client

See [VALIDATION.md](VALIDATION.md) for a layered command-by-command runbook to confirm the lab is working end to end (kernel MPLS → IS-IS/SR → BGP → VPN dataplane → BGP-LU → SR-TE).

## Accessing the Container Shell

The container shell can be accessed by using the `docker exec` command, as follows:

```shell
docker exec -it <container> bash
```

For example, to access the shell on the `pe1` FRR container:

```shell
docker exec -it clab-frr-sr-mpls-pe1 bash
```

## Accessing the FRR CLI (vtysh)

The FRR CLI can be accessed by using the `docker exec` command, as follows:

```shell
docker exec -it <container> vtysh
```

For example, to access the FRR CLI on the `pe1` container:

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh
```

## Capturing Packets

Here is an example on how to capture packets directly on the host which CONTAINERlab is running:

```shell
sudo ip netns exec clab-frr-sr-mpls-pe1 tcpdump -nni eth1
```

## Cleanup

Stop the lab and tear down the CONTAINERlab containers:

```shell
clab destroy -t lab.yml
```

## Author

- Darren Bono - [darren.bono@att.net](mailto://darren.bono@att.net)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details

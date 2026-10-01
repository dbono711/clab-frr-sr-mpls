# clab-frr-sr-mpls

## Overview

A Segment Routing MPLS (SR-MPLS) network using [CONTAINERlab](https://containerlab.dev/) and [FRRouting (FRR)](https://frrouting.org/) nodes to demonstrate [SR-MPLS](https://docs.frrouting.org/en/latest/isisd.html#segment-routing) capabilities in a controlled lab environment.

This lab provides a practical environment for learning and testing core SR-MPLS concepts including the SRGB, IS-IS Prefix-SIDs, SR-MPLS transport for BGP L3VPN services (IPv4 forwarding end-to-end; the IPv6 control plane is exercised but cannot install — see "IPv6 in the VRFs"), global-table BGP transport riding the same SR-MPLS underlay, and a live PCEP session to an external PCE ([`pola`](https://github.com/nttcom/pola)) as the foundation for SR-TE policy control.

## Requirements

- [CONTAINERlab](https://containerlab.dev/install/)
  - _The [CONTAINERlab](https://containerlab.dev/install/) installation guide outlines various installation methods. This lab assumes all [pre-requisites](https://containerlab.dev/install/#pre-requisites) (including Docker) are met and CONTAINERlab is installed via the [install script](https://containerlab.dev/install/#install-script)._
- Docker FRR image: `quay.io/frrouting/frr:10.7.1` (will be downloaded automatically)
- Docker Network Multitool image: `wbitt/network-multitool:alpine-extra` (for client nodes) (will be downloaded automatically)
- Docker pola (PCE) image: `ghcr.io/nttcom/pola:v1.3.3` (will be downloaded automatically)
- **Host MPLS kernel modules**: containers here share the host kernel's MPLS dataplane, so the host must load the MPLS modules before deploying:

  ```shell
  sudo modprobe mpls_router mpls_iptunnel mpls_gso
  ```

  `make lab` runs this automatically; if you deploy directly with `clab deploy` instead of `make lab`, run it yourself first.

## Topology

![Lab topology](images/topology.png)

## Network Resources

- Loopback addresses double as router IDs (BGP, IS-IS), allocated from the `172.16.0.0/24` block and follow the format `172.16.0.y/32`, where `y` is assigned per device.
- All routers are part of IS-IS Level 2 with IS-IS NET addresses derived from the router ID, using the format `49.0001.1721.6000.00yy.00`, where `yy` is the loopback's last octet zero-padded to 4 digits (e.g., `49.0001.1721.6000.0011.00` for pe11).
- BGP is configured on the PEs (pe11, pe12), the border router (bdr13), and the route reflector (rr14) — all ASN 65000.
- `pe11`, `pe12`, and `rr14` each carry an `ipv6 address 2001:db8::y/128` on `lo` alongside the IPv4 loopback — **unrouted, deliberately not advertised into IS-IS**, and present for exactly one reason: FRR refuses to negotiate `address-family ipv6 vpn` (which all three activate, for the RED/BLUE VRFs' IPv6 side) with **zero** local IPv6 addresses anywhere on the router, failing the *entire* session with `Cease/Unspecific` rather than just that AF. It is a session-enablement placeholder and nothing more. `bdr13` never activates `ipv6 vpn`, so it doesn't need one.

| Node | Role | Loopback / Router ID | IS-IS NET | Prefix-SID Index | Label |
|---|---|---|---|---|---|
| pe11  | PE (SR-TE / PCEP headend) | 172.16.0.11/32 | 49.0001.1721.6000.0011.00 | 111 | 16111 |
| pe12  | PE | 172.16.0.12/32 | 49.0001.1721.6000.0012.00 | 112 | 16112 |
| p1    | Core | 172.16.0.2/32  | 49.0001.1721.6000.0002.00 | 102 | 16102 |
| p2    | Core | 172.16.0.3/32  | 49.0001.1721.6000.0003.00 | 103 | 16103 |
| p3    | Core | 172.16.0.4/32  | 49.0001.1721.6000.0004.00 | 104 | 16104 |
| p4    | Core | 172.16.0.5/32  | 49.0001.1721.6000.0005.00 | 105 | 16105 |
| p5    | Core | 172.16.0.6/32  | 49.0001.1721.6000.0006.00 | 106 | 16106 |
| p6    | Core | 172.16.0.7/32  | 49.0001.1721.6000.0007.00 | 107 | 16107 |
| bdr13 | Border | 172.16.0.13/32 | 49.0001.1721.6000.0013.00 | 113 | 16113 |
| rr14  | Route Reflector | 172.16.0.14/32 | 49.0001.1721.6000.0014.00 | — (no SR dataplane role) | — |

`rr14` runs IS-IS purely for loopback reachability and iBGP `update-source` — it has no `segment-routing on`, no Prefix-SID, and no MPLS sysctl setup in its init script. It never forwards labeled traffic; it's a control-plane-only leaf off `p1`.

### Core (Underlay) Topology

Six core routers (`p1`–`p6`) form a ring (`p1—p2—p3—p6—p5—p4—p1`) with one diagonal chord (`p2—p5`). `p2—p5` and `p5—p6` both carry an `isis metric 100` bump on both ends, biasing SPF away from that side of the ring. All links are IPv4 `/31`s (RFC 3021), packed sequentially within a single `10.0.1.0/24` block:

| Link | Subnet | IS-IS Metric |
|---|---|---|
| pe11–p1  (eth1/eth1) | 10.0.1.0/31  | default |
| p1–p2    (eth2/eth1) | 10.0.1.2/31  | default |
| p2–p3    (eth2/eth1) | 10.0.1.4/31  | default |
| p4–p5    (eth3/eth1) | 10.0.1.6/31  | default |
| p5–p6    (eth2/eth2) | 10.0.1.8/31  | **100** (both directions) |
| p1–p4    (eth3/eth1) | 10.0.1.10/31 | default |
| p2–p5    (eth3/eth3) | 10.0.1.12/31 | **100** (both directions) |
| p3–p6    (eth3/eth1) | 10.0.1.14/31 | default |
| pe12–p6  (eth1/eth3) | 10.0.1.16/31 | default |
| bdr13–p3 (eth1/eth2) | 10.0.1.18/31 | default |
| rr14–p1  (eth1/eth4) | 10.0.1.20/31 | default |
| pe11–p4  (eth2/eth2) | 10.0.1.22/31 | default |
| pe12–p3  (eth2/eth4) | 10.0.1.24/31 | default |

Edge attachments: `pe11` connects to **both** `p1` and `p4`; `pe12` connects to **both** `p6` and `p3`; `bdr13` (border) connects to `p3`; `rr14` (route reflector) connects to `p1`.

Dual-homing each PE into two different points on the ring creates two fully disjoint 4-hop paths between `pe11` and `pe12`:

| Path | Hops | Cost |
|---|---|---|
| `pe11–p1–p2–p3–pe12` | 4 | **40** (all default metric 10) |
| `pe11–p4–p5–p6–pe12` | 4 | **130** (traverses the metric-100 `p5–p6` link) |

This asymmetry gives the lab a "good" path and a path SPF will never choose on its own, which is precisely what constraint-based selection (Flex-Algo affinity, SR-TE) exists to override.

### Link Affinities

Each of those two disjoint paths is colored with an IS-IS Flex-Algo affinity, so a future Flex-Algo Definition can constrain computation to one plane or the other:

```text
affinity-map RED bit-position 0
affinity-map BLUE bit-position 1
```

Both maps are defined identically on every SR-capable node (bit positions stay ≤31 so they remain compatible with Standard Administrative-Group). Interfaces are colored via zebra's `link-params` block on **both** ends of each link:

```text
interface eth1
 link-params
  affinity RED
 exit-link-params
exit
```

| Affinity | Links (both ends colored) |
|---|---|
| RED  | `pe11:eth1↔p1:eth1`, `p1:eth2↔p2:eth1`, `p2:eth2↔p3:eth1`, `p3:eth4↔pe12:eth2` |
| BLUE | `pe11:eth2↔p4:eth2`, `p4:eth3↔p5:eth1`, `p5:eth2↔p6:eth2`, `p6:eth3↔pe12:eth1` |

The cross-links (`p1↔p4`, `p2↔p5`, `p3↔p6`) and the `rr14`/`bdr13` attachments are intentionally left uncolored — they're the rungs between the two planes, and leaving them without an affinity means an `include-any`-constrained Flex-Algo can't hop between RED and BLUE mid-path.

### Segment Routing Label Ranges

Kept disjoint to avoid collisions:

| Purpose | Range | Mechanism |
|---|---|---|
| SRGB (IS-IS Prefix-SID, all SR nodes) | 16000–23999 | FRR default — **not** explicitly configured |
| pathd SR-TE binding-SIDs (static) | 30000–30099 | `binding-sid` under `policy color ...` |
| zebra dynamic label pool (BGP `label vpn export auto`) | 700000–799999 | `mpls label dynamic-block 700000 799999` |

### Client / VRF Prefixes

- **RED VRF**: pe11 `10.10.1.0/30` + `2001:c0de:10:1::/64` (client c1), pe12 `10.10.2.0/30` + `2001:c0de:10:2::/64` (client c2). RD `172.16.0.<pe>:10`, RT `65000:10`.
- **BLUE VRF**: pe11 `10.10.1.4/30` + `2001:c0de:10:3::/64` (client c1), pe12 `10.10.2.4/30` + `2001:c0de:10:4::/64` (client c2). RD `172.16.0.<pe>:20`, RT `65000:20`.
- **Global table**: pe11↔c3 `10.11.1.0/30` (a third client, `c3`, attached to `pe11` on a separate interface, outside any VRF); bdr13's simulated Internet loopback `internet0` = `99.99.99.99/32`.

### Management Network

| Node  | Management IP  |
|-------|-----------------|
| pola  | 172.28.1.20/24  |
| pe11  | 172.28.1.11/24  |
| pe12  | 172.28.1.12/24  |
| p1    | 172.28.1.2/24   |
| p2    | 172.28.1.3/24   |
| p3    | 172.28.1.4/24   |
| p4    | 172.28.1.5/24   |
| p5    | 172.28.1.6/24   |
| p6    | 172.28.1.7/24   |
| bdr13 | 172.28.1.13/24  |
| rr14  | 172.28.1.14/24  |
| c1    | 172.28.1.30/24  |
| c2    | 172.28.1.31/24  |
| c3    | 172.28.1.32/24  |

## SR-MPLS-based L3VPN Services

This lab demonstrates SR-MPLS as the transport for L3VPN services, using IS-IS-distributed Prefix-SIDs as the underlay label-switched path to each PE's loopback:

- One SRGB, one Prefix-SID per node — no LDP, no RSVP-TE.
- L3VPN control plane is plain multiprotocol BGP (vpnv4 / vpnv6 address families) — same as classic BGP/MPLS L3VPN (RFC 4364).
- SR-MPLS just pushes/swaps/pops labels; the "service SID" is a normal MPLS VPN label.

### SR-MPLS Setup

- **SRGB**: no `segment-routing global-block` is configured anywhere — every SR-capable node (pe11, pe12, p1–p6, bdr13) uses FRR's **default** SRGB of `16000–23999`, so label = `16000 + index`. Each node sets `segment-routing on` and `segment-routing node-msd 8`.
- **Prefix-SID**: each SR-capable node advertises its loopback with `segment-routing prefix <loopback>/32 index <N>` (see the table above for the index/label mapping — label = SRGB base + index).
- **No encapsulation-behavior required**: the underlay LSP toward a remote PE's loopback comes purely from IS-IS SR, and VPN traffic rides it via an ordinary imposed VPN label.

### TI-LFA Fast Reroute

Every ISIS interface on every SR-capable node (`pe11`, `pe12`, `p1`–`p6`, `bdr13`) runs:

```text
isis fast-reroute ti-lfa level-2 node-protection link-fallback
```

`rr14` is excluded — it has no `segment-routing on` and no SR dataplane role. Node-protection is the primary mode (protects against the *next router* failing, not just the link to it); `link-fallback` still computes a link-protecting repair path for any destination where node-protection isn't computable. Repair paths are precomputed continuously, so failover on a link/node failure is a local, sub-second decision — it doesn't wait for IS-IS to flood the failure and recompute SPF domain-wide.

The repair path is built from a transit node SID followed by **adjacency SIDs**, which is what makes it a strict path — it can't loosely reroute back over a link it just traversed the way a hand-built node-SID-only segment list can. Node protection is observable too; failing `pe11`'s link to `p1` produces a repair that avoids `p1` entirely rather than just the failed link.

#### Testing TI-LFA requires deliberately slowing SPF

Default reconvergence is **too fast to observe**. Detection, backup activation, and the PLR's own SPF recomputation are all local — the PLR never waits to hear from another node — so the repair window is tens of milliseconds and usually carries zero packets. That's exactly the behaviour you want in production, but it means a naive test can't distinguish TI-LFA from ordinary SPF reconvergence: at 1 pps both show zero loss.

The technique that works is to keep detection instant but delay SPF on the PLR (RFC 8405, milliseconds), so the precomputed backup stays in the forwarding path long enough to see:

```text
router isis 1
 spf-delay-ietf init-delay 30000 short-delay 30000 long-delay 30000 holddown 60000 time-to-learn 30000
```

With that applied, a packet capture on the backup egress shows the multi-label repair stack for the whole delay window, then a clean switch to the single-label post-convergence path. This is a **lab instrument, not lab configuration** — it is applied temporarily during a test and removed afterward. Full procedure in [VALIDATION.md](VALIDATION.md) Layer 4.

### Flex-Algo — intended design, NOT configured (blocked upstream)

Flex-Algo is **not present in this lab's configuration**. It was built, tested, and removed after confirming it cannot work here. The link colouring above stays in place — it's functional and independently useful — but nothing currently consumes it inside the IGP.

**Why it's blocked**: [FRR issue #20022](https://github.com/FRRouting/frr/issues/20022), open and unfixed, with no maintainer response and no identified root cause. Flex-Algo does not work in an `is-type level-2-only` IS-IS domain: configuration is accepted at runtime, but the Flex-Algo Definition is never advertised or elected and per-algorithm node SID labels are never distributed. `show isis flex-algo` reports `Source: Not found` on every node. Confirmed upstream on 10.1.1 and 10.4.1; reproduced here on 10.7.1.

**The design that should work**, recorded for when the bug is fixed:

| Algo | Plane | Participants | Constraint | Metric |
|---|---|---|---|---|
| 128 | RED  | pe11, p1, p2, p3, pe12 | `affinity include-any RED`  | igp |
| 129 | BLUE | pe11, p4, p5, p6, pe12 | `affinity include-any BLUE` | igp |

Per participating node, under `router isis 1`:

```text
flex-algo 128
 advertise-definition
 dataplane sr-mpls
 affinity include-any RED
 metric-type igp
exit
!
segment-routing prefix 172.16.0.11/32 algorithm 128 index 211
```

Per-algo Prefix-SID index would be `200 + last loopback octet` for algo 128 and `300 + octet` for algo 129 — making `pe12` reachable as label **16212** via the RED plane and **16312** via the BLUE plane, alongside its algo-0 label 16112. All participants advertise an identical FAD at equal priority, so whichever definition wins election is the same one. `bdr13`/`rr14` would participate in neither, leaving `bdr13`'s loopback reachable only via algo 0.

Additional notes:

- **`mpls-te on` under `router isis 1` is a hard prerequisite**. It's what makes IS-IS flood the admin-group/ASLA sub-TLVs that affinity constraints match against — without it there are no admin-groups in the LSDB at all and `include-any RED` would match nothing.
- **`metric-type igp` is FRR's default and never appears in `show running-config`.** Its absence is not a rejection. FRR also only *implements* the IGP metric type — `te`/`delay` are advertised but disable the algorithm locally.
- FRR mislabels algorithms 128–255 as `"Strict SPF"` in `segmentRoutingAlgorithm` output (1 is actually Strict SPF). Cosmetic only.

### BGP L3VPN Setup

- **VRF Configuration**: RED and BLUE VRFs are configured on both PE routers (pe11 and pe12) for the IPv4 and IPv6 unicast address families.
- **Client Connectivity**: c1 and c2 connect to pe11 and pe12 respectively through VLAN interfaces assigned to both VRFs — VLAN 10 for RED, VLAN 20 for BLUE.
- **Route Distinguishers and Route Targets**: RED uses `*:10` / `65000:10`, BLUE uses `*:20` / `65000:20`.
- **Per-AF Label Model**: `label vpn export auto` is configured inside **each** `address-family ipv4 unicast` / `ipv6 unicast` block (not at the vrf-instance level — FRR requires it nested under the AF, same as `rd vpn export`). FRR/zebra dynamically allocates one MPLS VPN label per AF per VRF (drawn from the `700000–799999` dynamic pool) — so RED gets two labels (one for its IPv4 side, one for IPv6).
- **End-to-End Service**: BGP L3VPN exchanges routes between matching VRFs on the PEs via the route reflector (`rr14`), while the SR-MPLS underlay (IS-IS Prefix-SID LSPs) provides the data-plane transport across the core.

### IPv6 in the VRFs (6VPE) — control plane works, dataplane blocked by the Linux kernel

**Status: parked.** The RED/BLUE IPv6 configuration on the
client-PE side is deliberately retained and fully functional up to the point of route installation —
`ping6` between `c1` and `c2` does not work and is not expected to. The configuration stays because
it is correct; what fails is below FRR.

What does work: `pe12` originates `2001:c0de:10:2::/64` from VRF RED, exports it to vpnv6 with a VPN
label, `rr14` reflects it, and `pe11` receives it and imports it into VRF RED. Verifiable at every
step with `show bgp ipv6 vpn` / `show bgp vrf RED ipv6 unicast`. The entire BGP/MPLS L3VPN control
plane for IPv6 is exercised and provable.

What fails: the route never reaches `show ipv6 route vrf RED`, because there is no way to express its
forwarding entry on Linux.

**Root cause — Linux cannot install an IPv6 route with an IPv4 next-hop.** Proper 6VPE (RFC 4659)
and 6PE (RFC 4798) both carry an IPv4-mapped next-hop so the IPv6 service route resolves recursively through the IPv4 underlay — that is the entire point, and it is what keeps
the core IPv4-only. FRR does this correctly. The kernel then refuses the result outright:

```
# ip -6 route add 2001:c0de:10:2::/64 encap mpls 16112/700003 via inet 10.0.1.1 dev eth1
Error: IPv6 does not support RTA_VIA attribute.
```

`net/ipv6/route.c` rejects `RTA_VIA` unconditionally: an `AF_INET6` route cannot name a non-IPv6
gateway, whatever encapsulation it carries. The symptom in FRR is a route that looks completely
correct and is marked `B>r` (rejected), with `Route install failed` and `RTM_NEWROUTE ... Invalid
argument` in the log. Cisco and Juniper do this in hardware; Linux has no expression for it, and no
amount of FRR configuration can supply a missing netlink attribute.

The same command with an **IPv6** next-hop is accepted, and forwards correctly over the unmodified

IPv4-only core:

```
# ip -6 route add 2001:c0de:10:2::/64 encap mpls 16112/700003 via inet6 fe80::a8c1:abff:fe30:f964 dev eth1 vrf RED
# ...ping6 from c1 to c2 then succeeds
```

So the blocker is specifically the mixed address family, not MPLS encapsulation on IPv6 routes, and
not the label stack, which FRR had already computed correctly.

#### A testing trap worth recording

FRR selects the local vpnv6 next-hop **at session establishment and caches it**. Changing `lo`
addresses, or applying an outbound `set ipv6 next-hop global` route-map, on a running `bgpd` does not
recompute it — even after `clear bgp ipv6 vpn * soft out`, which re-sends the attribute without
recomputing the cached local value. **Verify vpnv6 next-hop behaviour on a fresh `make lab`, never on a
live edit.**

## Global Table: Plain BGP over the SR-MPLS Underlay

`pe11` originates the client3-connected subnet `10.11.1.0/30`, and `bdr13` originates the simulated Internet loopback `99.99.99.99/32` — both under a plain `address-family ipv4 unicast` `network` statement in the **default** BGP instance, with `neighbor RR activate` / `next-hop-self` toward `rr14`. There is no VRF, and no BGP Labeled-Unicast (RFC 3107) involved.

This works without a per-prefix BGP label because neither prefix needs one: `99.99.99.99/32` is a directly-connected address on `bdr13` itself (the `internet0` dummy interface), not a further destination behind it. Forwarding just recurses the BGP next-hop (`bdr13`'s loopback) through the IS-IS SR LSP already in place for that loopback's Prefix-SID — the same mechanism any ordinary BGP route uses to cross an MPLS-label-switched core without a VRF boundary to cross. `pe11` imposes `bdr13`'s Prefix-SID label, the core label-switches it hop by hop, the label gets popped at/before `bdr13`, and `bdr13` does an ordinary local-address lookup and delivers it.

Verify with:

```shell
docker exec -it clab-frr-sr-mpls-c3 ping -c 5 99.99.99.99
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route 99.99.99.99/32"
docker exec -it clab-frr-sr-mpls-bdr13 vtysh -c "show ip route 10.11.1.0/30"
```

## PCEP / SR-TE Control Plane (pola)

`pe11` runs `pathd` and is configured with a live PCEP session to an external PCE, [`pola`](https://github.com/nttcom/pola) (`ghcr.io/nttcom/pola:v1.3.3`, deployed as its own containerlab node at `172.28.1.20`):

```text
segment-routing
 traffic-eng
  pcep
   pce POLA
    address ip 172.28.1.20
    source-address ip 172.28.1.11
    pce-initiated
   pcc
    peer POLA
```

`pe11` is the only node running `pathd`/carrying this configuration; no other PE or core node participates.

Verify the PCEP session itself:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te pcep session"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te pcep pcc"
docker exec -it clab-frr-sr-mpls-pola pola session list
```

### BGP-LS / TED — built, proven, and parked

A full BGP-LS feed into a `gobgp` collector is configured and **works end to end**, but the data FRR sends is unusable for SR-MPLS path computation. Do not debug this as a config problem.

The pipeline: `pe11` → `mpls-te export` → zebra ZAPI opaque link-state → bgpd `address-family link-state link-state` → BGP-LS session → `gobgp` (172.28.1.21) → gRPC → pola.

```text
router isis 1
 mpls-te on
 mpls-te export
exit
!
router bgp 65000
 neighbor 172.28.1.21 remote-as internal
 address-family link-state link-state
  neighbor 172.28.1.21 activate
 exit-address-family
exit
```

**What works**: 50+ NLRIs reach `gobgp` — node, link and prefix — carrying node names, IS-IS area, router IDs, per-node **SR Capabilities (SRGB `16000:24000`)**, IGP metrics and bandwidth.

**The blocker — FRR 10.7.1's BGP-LS encoder omits the Prefix-SID.** Every PREFIXv4 NLRI arrives with an empty attribute set (`"prefix":{}` in `gobgp global rib -a ls -j`), including every loopback. A label is `SRGB base + index`; pola receives the base and never the index, so it cannot construct a label stack for any destination. Dynamic SR-MPLS path computation is therefore **not achievable on this FRR version**, regardless of configuration.

Two further encoder defects found while proving this:

- **Admin-groups and adjacency-SIDs are not encoded either.** Link NLRIs carry only `igp_metric`, `bandwidth`, `reservable_bandwidth`, `unreserved_bandwidth`. The `Ext Admin Group: 0x1/0x2` present in `show isis mpls-te database` never reaches BGP-LS, so affinity-constrained PCE-side computation is also out.
- **Link metric is corrupted in transit.** `p5↔p6` is configured `isis metric 100` and appears correctly as `Metric: 100` in the TED, but arrives as `"igp_metric":36` over BGP-LS.

Two design notes worth keeping:

- **`mpls-te export` exports the full LSDB**. `mpls-te export` on `pe11` produced all 50+. This also means the core does **not** need `bgpd` enabled on P routers; one exporter covers the whole topology. (The command is mutually exclusive with `distribute link-state`.)

Consequence for pola generally: both routes to using it are currently blocked. Dynamic paths need the TED, which needs Prefix-SIDs FRR doesn't send. Explicit paths don't need the TED but require `pola sr-policy add -s`, and that flag is broken in pola v1.3.3 — `addSRPolicyWithoutSIDValidation()` sets neither `Asn` nor `SidValidate`, so the request still lands in the TED-requiring server branch. Using pola requires either an FRR BGP-LS fix or a one-line pola patch.

`ted.enable` is deliberately left **true** in `pola/polad.yaml` so the feed starts working the moment the upstream gap closes. [VALIDATION.md](VALIDATION.md) Layer 9 carries a revisit checklist — the exact commands, with what a *working* feed should return in each one alongside what 10.7.1 currently returns.

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

See [VALIDATION.md](VALIDATION.md) for a layered command-by-command runbook to confirm the lab is working end to end.

## Accessing the Container Shell

```shell
docker exec -it <container> bash
```

For example, to access the shell on the `pe11` FRR container:

```shell
docker exec -it clab-frr-sr-mpls-pe11 bash
```

## Accessing the FRR CLI (vtysh)

```shell
docker exec -it <container> vtysh
```

For example, to access the FRR CLI on the `pe11` container:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh
```

`pola` is not an FRR node — it has no `vtysh`. Interact with it via its own CLI inside the container:

```shell
docker exec -it clab-frr-sr-mpls-pola pola sr-policy list
```

## Capturing Packets

```shell
sudo ip netns exec clab-frr-sr-mpls-pe11 tcpdump -nni eth1
```

## Cleanup

```shell
clab destroy -t lab.yml
```

## Author

- Darren Bono - [darren.bono@att.net](mailto://darren.bono@att.net)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details

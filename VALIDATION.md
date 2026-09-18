# Validation Runbook

A layered, bottom-up command set for proving `clab-frr-sr-mpls` works end to end. Each layer depends on the one below it — if a layer fails, fix it before checking the next one up; don't chase a BGP symptom that's actually an unloaded kernel module.

Container names follow `clab-frr-sr-mpls-<node>` (e.g. `clab-frr-sr-mpls-pe1`).

---

## 1. Deploy

```shell
cd clab-frr-sr-mpls
make lab
# or directly:
sudo clab deploy -t lab.yml
```

```shell
sudo clab inspect -t lab.yml
```

Confirm all 11 containers (`pe1`, `pe2`, `p1`–`p4`, `rr`, `bdr1`, `c1`–`c3`) show `running`.

---

## Layer 1 — Kernel MPLS dataplane

Per SR-capable node (`pe1`, `pe2`, `p1`–`p4`, `bdr1`):

```shell
docker exec -it clab-frr-sr-mpls-p1 sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.eth3.input net.mpls.conf.eth4.input net.mpls.conf.lo.input net.mpls.platform_labels
```

(swap the `net.mpls.conf.ethN` list per node — `pe1`/`pe2`/`bdr1` only have `eth1`+`lo`; see each node's `.sh` for its exact interface list.) Every value should read `= 1`, and `platform_labels` should read `= 1048575`. All-zero here means Layer 0 wasn't done before deploy, or the container was restarted without re-running its init script.

```shell
docker exec -it clab-frr-sr-mpls-p1 ip -f mpls route show
```

---

## Layer 2 — IS-IS adjacencies

Per SR-capable node, including `rr`:

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis neighbor"
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis interface"
```

Every node should show `Up` adjacencies matching `lab.yml`'s link map (e.g. `p1` ↔ `pe1`, `p2`, `p3`, `rr`).

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show ip route isis"
```

Every node should have an ISIS-learned `/32` route to every other node's loopback (`172.16.0.1`–`.6`, `.8`, `.15`).

---

## Layer 3 — Segment Routing label programming

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis segment-routing node"
```

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show mpls table"
```

Expect one incoming-label entry per remote SR node, e.g. incoming label `16102` (p1's SID) with an outgoing swap/pop toward `eth1`. Cross-check the label math: label = SRGB base (`16000`) + Prefix-SID index (e.g. `102` for p1) = `16102`.

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show ip route 172.16.0.6/32"
```

pe1's route to pe2's loopback should resolve via a labeled nexthop (look for a `label` annotation in the output) — this is the underlay LSP that VPN traffic rides.

Kernel-side cross-check:

```shell
docker exec -it clab-frr-sr-mpls-p1 ip -f mpls route show
```

Should be non-empty, mirroring `show mpls table` in FRR.

---

## Layer 4 — BGP sessions (Edge / RR)

Let's check the BGP sessions from the RR to the PEs:

```shell
docker exec -it clab-frr-sr-mpls-rr vtysh -c "show bgp summary"
```

Expect `Established` sessions to `pe1` (172.16.0.1), `pe2` (172.16.0.6), `bdr1` (172.16.0.15) across the `ipv4 vpn`, `ipv6 vpn`, and `ipv4 labeled-unicast` SAFI tables.

Check BGP sessions to the RR on some of the provider edge nodes:

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp summary"
docker exec -it clab-frr-sr-mpls-bdr1 vtysh -c "show bgp summary"
```

If any session is stuck in `Active`/`Connect`, check `update-source`/loopback reachability (Layer 2/3 must be up first — these are iBGP sessions riding the ISIS-learned loopback routes, not directly connected).

**If a session sits in `Idle` with `Connections established 0` despite loopback reachability confirmed (ping works) and OPENs actually being exchanged (`Opens: Sent N Rcvd N` both nonzero, `Notifications: Sent N Rcvd 0`)** — this isn't a reachability or capability-negotiation problem, it's `pe1`/`pe2`/`rr` missing their `ipv6 address ::ffff:172.16.0.y/128` on `lo`. Confirm via the log, which will show the exact fatal error before the `Cease`:

```shell
docker exec -it clab-frr-sr-mpls-pe1 grep -i "No local IPv6 address" /etc/frr/logs/pe1.log
```

If that line is present, the `lo` interface is missing its IPv6 address (FRR won't negotiate `address-family ipv6 vpn` — needed for BLUE/RED's IPv6 side — without at least one local IPv6 address anywhere on the router, and fails the *entire* session rather than just that AF). `bdr1` never activates `ipv6 vpn`, so it's unaffected and will establish normally even without one.

---

## Layer 5 — BGP L3VPN control plane (RED)

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp vrf RED ipv4 unicast"
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp vrf RED ipv6 unicast"
```

Each PE should see the **other** PE's connected client subnet (e.g. pe1 sees pe2's `10.10.2.0/30` in RED) as a VPN-imported route.

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp ipv4 vpn"
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp ipv6 vpn"
```

Confirm the RD (`172.16.0.1:10` / `172.16.0.6:10` for RED) and RT (`65000:10`) look right, and that a label is attached to each path. For the `ipv6 vpn` entries specifically, check the next-hop: it must be `::ffff:172.16.0.y` (IPv4-mapped).

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp labelpool summary"
```

Confirms `label vpn export auto` pulled labels from the `700000–799999` dynamic block (zebra's `mpls label dynamic-block`) rather than failing silently.

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show ip route vrf RED"
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show ipv6 route vrf RED"
```

Should show the remote PE's client subnet installed with an MPLS label stack (VPN label + underlay SR label) — for **both** AFs. If `show bgp vrf RED ipv6 unicast` shows a valid `*>` best path but `show ipv6 route vrf RED` doesn't have it, that's a next-hop resolution failure, not a BGP problem — go back to the next-hop check above.

---

## Layer 6 — RED / BLUE dataplane (client-to-client)

| From | RED target | BLUE target |
|---|---|---|
| c1 → c2 | `10.10.2.2` / `2001:c0de:10:2::2` | `10.10.2.6` / `2001:c0de:10:4::2` |
| c2 → c1 | `10.10.1.2` / `2001:c0de:10:1::2` | `10.10.1.6` / `2001:c0de:10:3::2` |

```shell
docker exec -it clab-frr-sr-mpls-c1 ping -c 5 10.10.2.2
docker exec -it clab-frr-sr-mpls-c1 ping -c 5 2001:c0de:10:2::2
docker exec -it clab-frr-sr-mpls-c1 ping -c 5 10.10.2.6
docker exec -it clab-frr-sr-mpls-c1 ping -c 5 2001:c0de:10:4::2
```

All four should succeed. This is the actual end-to-end proof that SR-MPLS transport + BGP/MPLS VPN works — everything in Layers 1–5 is just confirming the plumbing behind this result.

---

## Layer 7 — BGP Labeled-Unicast global table (pe1 ↔ bdr1)

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp ipv4 labeled-unicast"
docker exec -it clab-frr-sr-mpls-bdr1 vtysh -c "show bgp ipv4 labeled-unicast"
docker exec -it clab-frr-sr-mpls-rr vtysh -c "show bgp ipv4 labeled-unicast summary"
```

pe1 should see `99.99.99.99/32` (bdr1's origin), bdr1 should see `10.11.1.0/30` (pe1's origin), each with a label attached — this is the RFC 3107 label advertised alongside the NLRI.

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show ip route 99.99.99.99/32"
docker exec -it clab-frr-sr-mpls-bdr1 vtysh -c "show ip route 10.11.1.0/30"
```

Both should resolve via a labeled nexthop in the **default** table — no VRF involved anywhere.

```shell
docker exec -it clab-frr-sr-mpls-c3 ping -c 5 99.99.99.99
```

---

## Layer 8 — SR-TE manual steering (pathd, pe1 headend)

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show sr-te policy"
```
Confirmed against FRR source (`pathd/path_cli.c`) — the table columns are `Endpoint|Color|Name|BSID|Status`. Expect two rows: color `100`/BSID `30000` and color `200`/BSID `30001`, both endpoint `172.16.0.6`, status `Active` (not `Up` — that's the status string this command actually prints). `show sr-te policy detail` gives the full candidate-path/segment-list breakdown per policy.

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show mpls table"
```

Should now additionally show entries for binding-SIDs `30000`/`30001` alongside the underlay SR labels from Layer 3.

### Confirming the route-map steering (the flagged risk)

```shell
docker exec -it clab-frr-sr-mpls-pe1 vtysh -c "show bgp vrf RED ipv4 unicast 10.10.2.0/30"
```

Look for a `Color: 200` (or similarly labeled extended-community) annotation on the path. **This is the specific piece flagged as unvalidated in `README.md`/`CLAUDE.md`** — if the color extended-community isn't showing, or the route isn't resolving through the color-200 policy, the route-map attachment (`route-map vpn import STEER-RED-VIA-P3` under `router bgp 65000 vrf RED / address-family ipv4 unicast`) isn't taking effect as designed.

### Proving the path split on the wire

`p1` is the actual fork point (both segment-lists share pe1→p1 as the first hop; they diverge at p1 toward `p2` vs `p3`). Capture on each P-router's link back to `p1`:

```shell
sudo ip netns exec clab-frr-sr-mpls-p2 tcpdump -nni eth1 mpls
sudo ip netns exec clab-frr-sr-mpls-p3 tcpdump -nni eth1 mpls
```

Generate RED traffic from `c1`:

```shell
docker exec -it clab-frr-sr-mpls-c1 ping -c 20 10.10.2.2
```

**Expected if steering works:** traffic appears on `p3`'s capture, not `p2`'s (RED is colored 200 → `SEG-VIA-P3`). BLUE traffic (`c1` → `10.10.2.6`) should appear on `p2`'s capture instead (uncolored, rides plain ISIS SPF, which prefers `p2` since `p3`–`p4` carries the `isis metric 100` penalty).

**Fallback if the route-map steering doesn't take effect:** the policies and segment-lists themselves are still real and independently checkable via `show sr-te policy` and `show mpls table` above — treat it as a config-only SR-TE demonstration and note the gap rather than forcing it.

---

## Teardown

```shell
sudo clab destroy -t lab.yml
# or:
make clean
```

---

## Quick pass/fail checklist

| Layer | Command | Pass condition |
|---|---|---|
| 0 | `lsmod \| grep mpls` | 3 modules loaded |
| 1 | `sysctl net.mpls.conf.*.input` | all `= 1` |
| 2 | `show isis neighbor` | all expected adjacencies `Up` |
| 3 | `show mpls table` | one label per remote SR loopback |
| 4 | `show bgp summary` | RR sessions `Established` |
| 5 | `show bgp ipv4 vpn` | RD/RT/label present both PEs |
| 6 | `ping` c1↔c2 RED+BLUE, v4+v6 | 0% loss |
| 7 | `ping 99.99.99.99` from c3 | 0% loss |
| 8 | `show sr-te policy` | both policies `Active`; tcpdump confirms split |

# Validation Runbook

A layered, bottom-up command set for proving `clab-frr-sr-mpls` works end to end. Each layer depends on the one below it — if a layer fails, fix it before checking the next one up; don't chase a BGP symptom that's actually an unloaded kernel module.

Container names follow `clab-frr-sr-mpls-<node>` (e.g. `clab-frr-sr-mpls-pe11`). Current nodes: `pe11`, `pe12`, `p1`–`p6`, `bdr13`, `rr14`, `c1`–`c3`, `pola`.

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

Confirm all 14 containers (`pe11`, `pe12`, `p1`–`p6`, `bdr13`, `rr14`, `c1`–`c3`, `pola`) show `running`.

---

## Layer 1 — Kernel MPLS dataplane

Per SR-capable node, checking only the interfaces that node's `<node>.sh` actually enables (`rr14` has none — it has no SR/MPLS role and is skipped entirely at this layer):

```shell
docker exec -it clab-frr-sr-mpls-pe11 sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-pe12 sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-p1   sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.eth3.input net.mpls.conf.eth4.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-p2   sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.eth3.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-p3   sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.eth3.input net.mpls.conf.eth4.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-p4   sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.eth3.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-p5   sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.eth3.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-p6   sysctl net.mpls.conf.eth1.input net.mpls.conf.eth2.input net.mpls.conf.eth3.input net.mpls.conf.lo.input net.mpls.platform_labels
docker exec -it clab-frr-sr-mpls-bdr13 sysctl net.mpls.conf.eth1.input net.mpls.conf.lo.input net.mpls.platform_labels
```

Every value should read `= 1`, and `platform_labels` should read `= 1048575`. All-zero here means Layer 0 wasn't done before deploy, or the container was restarted without re-running its init script.

```shell
docker exec -it clab-frr-sr-mpls-p1 ip -f mpls route show
```

---

## Layer 2 — IS-IS adjacencies

Expected adjacency map (from `lab.yml`'s current link set):

| Node | Neighbors |
|---|---|
| pe11 | p1, p4 |
| pe12 | p6, p3 |
| p1 | pe11, p2, p4, rr14 |
| p2 | p1, p3, p5 |
| p3 | p2, p6, bdr13, pe12 |
| p4 | p1, p5, pe11 |
| p5 | p4, p2, p6 |
| p6 | p3, p5, pe12 |
| bdr13 | p3 |
| rr14 | p1 |

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis neighbor"
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis interface"
```

Repeat per node and confirm every adjacency listed above is `Up`.

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show ip route isis"
```

Every node should have an ISIS-learned `/32` route to every other node's loopback (`172.16.0.2`–`.7`, `.11`–`.14`).

---

## Layer 3 — Segment Routing label programming

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis segment-routing node"
```

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show mpls table"
```

Expect one incoming-label entry per remote SR node (9 total: `pe11`, `pe12`, `p1`–`p6`, `bdr13` — `rr14` never appears here, it has no Prefix-SID). Cross-check the label math: label = SRGB base (`16000`) + Prefix-SID index (`100 + last loopback octet`), e.g. `p5` (loopback `.6`) → index `106` → label `16106`.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route 172.16.0.12/32"
```

`pe11`'s route to `pe12`'s loopback should resolve via a labeled nexthop (look for a `label` annotation in the output) — this is the underlay LSP that VPN traffic rides.

Kernel-side cross-check:

```shell
docker exec -it clab-frr-sr-mpls-p1 ip -f mpls route show
```

Should be non-empty, mirroring `show mpls table` in FRR.

---

## Layer 4 — TI-LFA fast reroute

Every ISIS interface on every SR-capable node (`pe11`, `pe12`, `p1`–`p6`, `bdr13`) runs `isis fast-reroute ti-lfa level-2 node-protection link-fallback`. `rr14` is excluded — no `segment-routing on`, no SR dataplane role. Node-protection is the primary mode (protects against the next router failing, not just the link); `link-fallback` covers destinations where a node-protecting repair path isn't computable.

**Steady state** — confirm backups are precomputed before any failure:

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis fast-reroute summary"
```

Expect non-zero LFA-protected prefix counts and high/100% coverage.

```shell
docker exec -it clab-frr-sr-mpls-p2 vtysh -c "show isis route backup"
```

Look for `pe12`'s loopback (`172.16.0.12/32`) showing both a primary and a backup/repair nexthop.

**Failover** — `pe11` is now dual-homed (`p1` and `p4`), which gives two disjoint, equal-cost 4-hop paths to `pe12`: `p1-p2-p3` and `p4-p5-p6` (both cost 40; the `p2–p5`/`p5–p6` chord still carries the metric-100 penalty, so it's never on either shortest path). That means which path any given flow actually takes is an ECMP hash outcome, not a fixed assumption — **check first**, then fail a link on whichever path is actually in use:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route 172.16.0.12/32"
```

If it's riding `p1-p2-p3`, fail `p2↔p3`; if it's riding `p4-p5-p6`, fail `p4↔p5` or `p5↔p6` instead. Start continuous client traffic, then fail the link that's actually carrying it:

```shell
docker exec -it clab-frr-sr-mpls-c1 ping 10.10.2.2
```
```shell
docker exec -it clab-frr-sr-mpls-p2 vtysh -c "configure terminal" -c "interface eth2" -c "shutdown"
```

**Expected with TI-LFA working**: at most one or two dropped pings (sub-second local repair) — not the multi-second gap you'd see waiting for IS-IS to fully reconverge (flood LSPs, recompute SPF domain-wide). The local repair happens at the point of local repair — `p2` itself, the node directly upstream of the failed link — so confirm there first:

```shell
docker exec -it clab-frr-sr-mpls-p2 vtysh -c "show ip route 172.16.0.12/32"
docker exec -it clab-frr-sr-mpls-p2 vtysh -c "show mpls table"
```

Should reflect a repair nexthop other than the now-dead `eth2` immediately after the shutdown — with the ECMP topology, exactly which alternate path it lands on (back through `p1` toward the `p4-p5-p6` side, or some other repair) is worth just reading off the output rather than assuming.

**Recovery**:

```shell
docker exec -it clab-frr-sr-mpls-p2 vtysh -c "configure terminal" -c "interface eth2" -c "no shutdown"
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show ip route 172.16.0.12/32"
```

Confirm it settles back onto the original primary path via `p2` once IS-IS reconverges normally, and `show isis fast-reroute summary` on `p1` shows coverage restored.

---

## Layer 5 — BGP sessions (Edge / RR)

```shell
docker exec -it clab-frr-sr-mpls-rr14 vtysh -c "show bgp summary"
```

Expect `Established` iBGP sessions to `pe11` (172.16.0.11), `pe12` (172.16.0.12), `bdr13` (172.16.0.13) — across `ipv4 vpn` and `ipv6 vpn` for all three, but `ipv4 unicast` (the global-table SAFI) is only meaningfully populated by `pe11` and `bdr13` (the two nodes that actually originate a global-table prefix); `pe12` doesn't activate `ipv4 unicast` in its default BGP instance at all, so it won't show a route there even though the session itself is up.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp summary"
docker exec -it clab-frr-sr-mpls-bdr13 vtysh -c "show bgp summary"
```

If any session is stuck in `Active`/`Connect`, check `update-source`/loopback reachability (Layer 2/3 must be up first — these are iBGP sessions riding the ISIS-learned loopback routes, not directly connected).

**If a session sits in `Idle` with `Connections established 0` despite loopback reachability confirmed (ping works) and OPENs actually being exchanged (`Opens: Sent N Rcvd N` both nonzero, `Notifications: Sent N Rcvd 0`)** — this isn't a reachability or capability-negotiation problem, it's `pe11`/`pe12`/`rr14` missing their `ipv6 address ::ffff:172.16.0.y/128` on `lo`. Confirm via the log, which will show the exact fatal error before the `Cease`:

```shell
docker exec -it clab-frr-sr-mpls-pe11 grep -i "No local IPv6 address" /etc/frr/logs/pe11.log
```

If that line is present, the `lo` interface is missing its IPv6 address. `bdr13` never activates `ipv6 vpn`, so it's unaffected and will establish normally even without one.

---

## Layer 6 — BGP L3VPN control plane (RED)

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp vrf RED ipv4 unicast"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp vrf RED ipv6 unicast"
```

Each PE should see the **other** PE's connected client subnet (e.g. pe11 sees pe12's `10.10.2.0/30` in RED) as a VPN-imported route.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp ipv4 vpn"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp ipv6 vpn"
```

Confirm the RD (`172.16.0.11:10` / `172.16.0.12:10` for RED) and RT (`65000:10`) look right, and that a label is attached to each path. For the `ipv6 vpn` entries specifically, check the next-hop: it must be `::ffff:172.16.0.y` (IPv4-mapped).

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp labelpool summary"
```

Confirms `label vpn export auto` pulled labels from the `700000–799999` dynamic block rather than failing silently.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route vrf RED"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ipv6 route vrf RED"
```

Should show the remote PE's client subnet installed with an MPLS label stack (VPN label + underlay SR label) — for **both** AFs. If `show bgp vrf RED ipv6 unicast` shows a valid `*>` best path but `show ipv6 route vrf RED` doesn't have it, that's a next-hop resolution failure, not a BGP problem — go back to the next-hop check above.

---

## Layer 7 — RED / BLUE dataplane (client-to-client)

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

All four should succeed. This is the actual end-to-end proof that SR-MPLS transport + BGP/MPLS VPN works — everything in Layers 1–6 is just confirming the plumbing behind this result.

---

## Layer 8 — Global table (pe11 ↔ bdr13, plain BGP over the SR-MPLS underlay)

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp ipv4 unicast"
docker exec -it clab-frr-sr-mpls-bdr13 vtysh -c "show bgp ipv4 unicast"
```

`pe11` should see `99.99.99.99/32` (bdr13's origin); `bdr13` should see `10.11.1.0/30` (pe11's origin) — both in the default table, no VRF, no VPN label, no BGP Labeled-Unicast.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route 99.99.99.99/32"
docker exec -it clab-frr-sr-mpls-bdr13 vtysh -c "show ip route 10.11.1.0/30"
```

Both should resolve via a *labeled nexthop* — not because the prefix itself carries a label, but because the BGP next-hop (the other node's loopback) recurses through that loopback's IS-IS SR Prefix-SID LSP. That's the whole mechanism: no VRF, no RFC 3107, just an ordinary BGP route riding an SR-MPLS-label-switched path to its next-hop.

```shell
docker exec -it clab-frr-sr-mpls-c3 ping -c 5 99.99.99.99
```

---

## Layer 9 — PCEP session (pe11 ↔ pola)

**Scope note**: this layer currently validates the PCEP *session* only. `pe11/frr.conf` has no `segment-list`/`policy` blocks configured, so there is no SR-TE policy to verify end-to-end yet — see CLAUDE.md's "SR-TE / PCE state" note before assuming policy-level behavior.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te pcep session"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te pcep pcc"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te pcep counters"
```

Expect an established PCEP session to `pola` (`172.28.1.20`), sourced from `pe11`'s mgmt IP (`172.28.1.11`).

```shell
docker exec -it clab-frr-sr-mpls-pola pola session list
```

Should show `pe11` as a connected PCC from the `pola` side.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te policy"
```

Expect this to come back empty (no policies configured) until the SR-TE policy demo is rebuilt for the current topology.

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
| 1 | `sysctl net.mpls.conf.*.input` | all `= 1` (skip `rr14` — no SR role) |
| 2 | `show isis neighbor` | all expected adjacencies `Up`, per the map above |
| 3 | `show mpls table` | one label per remote SR loopback (9 nodes) |
| 4 | `show isis fast-reroute summary` | non-zero LFA coverage; failover test shows ≤2 dropped pings |
| 5 | `show bgp summary` | RR (`rr14`) sessions to `pe11`/`pe12`/`bdr13` `Established` |
| 6 | `show bgp ipv4 vpn` | RD/RT/label present both PEs |
| 7 | `ping` c1↔c2 RED+BLUE, v4+v6 | 0% loss |
| 8 | `ping 99.99.99.99` from c3 | 0% loss |
| 9 | `show sr-te pcep session` | session to `pola` `Established` (no policy check yet — none exist) |

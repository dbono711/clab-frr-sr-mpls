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

### Link affinities

Every SR-capable node defines the same two affinity maps; interfaces on the two disjoint PE-to-PE paths are colored on both ends.

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show running-config" | grep affinity
```

Expect `affinity-map RED bit-position 0` / `affinity-map BLUE bit-position 1` plus a `link-params` / `affinity <NAME>` / `exit-link-params` block on each colored interface.

Then confirm they're actually **advertised** — the colouring being in the local config doesn't mean IS-IS is flooding it. The LSDB is where this is visible; `show isis interface detail` does *not* display the admin-group:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show isis database detail" | grep -iE "Admin Group|Ext Admin Group"
```

Expected values — `0x1` = RED (bit-position 0), `0x2` = BLUE (bit-position 1)

| Affinity | Value | Links (both ends colored) |
|---|---|---|
| RED  | `0x1` | `pe11:eth1↔p1:eth1`, `p1:eth2↔p2:eth1`, `p2:eth2↔p3:eth1`, `p3:eth4↔pe12:eth2` |
| BLUE | `0x2` | `pe11:eth2↔p4:eth2`, `p4:eth3↔p5:eth1`, `p5:eth2↔p6:eth2`, `p6:eth3↔pe12:eth1` |

Cross-links (`p1↔p4`, `p2↔p5`, `p3↔p6`) and the `rr14`/`bdr13` attachments must show **no** admin-group at all — not `0x0`, genuinely absent. That's FRR's `admin-group-send-zero` default behaving correctly, and it's what keeps the two planes from being bridgeable by a constraint that matches "any colour".

**If no admin-groups appear anywhere**, the cause is a missing `mpls-te on` under `router isis 1` — that's the knob that makes isisd flood TE sub-TLVs, and without it the colouring is inert regardless of how the interfaces are configured. It's present on all 8 nodes with colored links for exactly this reason.

Nothing in the IGP consumes these affinities today (Flex-Algo is not configured — see below). This layer confirms the colouring is correctly advertised so it's ready for a consumer, whether that ends up being Flex-Algo upstream-fixed or `pola`'s TED via BGP-LS.

---

## Layer 3 — Segment Routing label programming

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis segment-routing node"
```

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show mpls table"
```

Expect one incoming-label entry per remote SR node (9 total: `pe11`, `pe12`, `p1`–`p6`, & `bdr13`. Cross-check the label math: label = SRGB base (`16000`) + Prefix-SID index (`100 + last loopback octet`), e.g. `p5` (loopback `.6`) → index `106` → label `16106`.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route 172.16.0.12/32"
```

`pe11`'s route to `pe12`'s loopback should resolve via a labeled nexthop (look for a `label` annotation in the output) — this is the underlay LSP that VPN traffic rides.

Kernel-side cross-check:

```shell
docker exec -it clab-frr-sr-mpls-p1 ip -f mpls route show
```

Should be non-empty, mirroring `show mpls table` in FRR.

### Flex-Algo — not configured

There is nothing to validate here. Flex-Algo is deliberately absent from this lab: it cannot work in an `is-type level-2-only` domain on FRR 10.7.1 ([FRR #20022](https://github.com/FRRouting/frr/issues/20022), open and unfixed). It was configured, proven broken, and removed. `show isis flex-algo` will return nothing, and `show isis topology` will only ever report `"algorithm":0` — both are expected.

See README's Flex-Algo section for the intended design and the symptoms to expect if it's ever re-enabled.

---

## Layer 4 — TI-LFA fast reroute

Every ISIS interface on every SR-capable node (`pe11`, `pe12`, `p1`–`p6`, `bdr13`) runs `isis fast-reroute ti-lfa level-2 node-protection link-fallback`. Node-protection is the primary mode (protects against the next router failing, not just the link); `link-fallback` covers destinations where a node-protecting repair path isn't computable.

**Steady state** — confirm backups are precomputed before any failure:

```shell
docker exec -it clab-frr-sr-mpls-p1 vtysh -c "show isis fast-reroute summary"
```

Expect non-zero LFA-protected prefix counts and high/100% coverage.

```shell
docker exec -it clab-frr-sr-mpls-p2 vtysh -c "show isis route backup"
```

Look for `pe12`'s loopback (`172.16.0.12/32`) showing both a primary and a backup/repair nexthop.

### Observing an actual failover — you must stall SPF first

**Default reconvergence is far too fast to catch.** Everything in the repair sequence is local to the point of local repair (PLR): link-down detection is an instant carrier/admin event, backup activation is a FIB swap to an already-computed nexthop, and the PLR's SPF recomputes from its own LSDB without waiting to hear from any other node. The repair window is tens of milliseconds and typically carries **zero packets**.

That's exactly what we want operationally, but it means a naive test proves nothing.

The working technique is to keep detection instant but stop the PLR from replacing the backup so quickly — delay SPF (RFC 8405, values in milliseconds). On the PLR only:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "configure terminal" -c "router isis 1" \
  -c "spf-delay-ietf init-delay 30000 short-delay 30000 long-delay 30000 holddown 60000 time-to-learn 30000"
```

`init-delay` is the operative knob — the delay before the first SPF after a topology change. The TI-LFA backup activates instantly on link-down and then **stays** the active forwarding path for that whole window.

Baseline the repair path, then run the test:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route 99.99.99.99 json"
```

Note the `backupNexthops` label stack (a multi-label repair stack via `eth2`) versus the single-label primary via `eth1`.

```shell
# terminal 1 — watch the backup egress
sudo ip netns exec clab-frr-sr-mpls-pe11 tcpdump -nni eth2 -ttt mpls

# terminal 2
docker exec -it clab-frr-sr-mpls-c3 ping -i 0.2 99.99.99.99

# terminal 3 — trigger
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "configure terminal" -c "interface eth1" -c "shutdown"
```

**What proves it**: packets egress `eth2` carrying the **multi-label repair stack** (transit node SID on top, then adjacency SIDs) for the full SPF-delay window, then switch to the **single** label `16113` once SPF finally runs and installs a new primary. That 4-labels→1-label transition is TI-LFA carrying traffic and then handing off. Mid-window the RIB shows it too — the backup nexthop marked installed/`fib` while the dead primary is still listed.

**Recovery, and remove the test instrument**:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "configure terminal" -c "interface eth1" -c "no shutdown"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "configure terminal" -c "router isis 1" -c "no spf-delay-ietf"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route 99.99.99.99 json"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show isis fast-reroute summary"
```

Confirm the primary settles back onto `eth1` and `backupNexthops` reappears. Note that while `eth1` is down, `pe11` is effectively single-homed for that destination and correctly has **no** backup — there's no alternate left to compute, which is right rather than broken.

The SPF delay is a lab instrument only — a 30s delay is pathological in production. If you want a permanent, less disruptive demo hook, `spf-delay-ietf init-delay 5000` is enough to be observable.

---

## Layer 5 — BGP sessions (Edge / RR)

```shell
docker exec -it clab-frr-sr-mpls-rr14 vtysh -c "show bgp summary"
```

Expect `Established` iBGP sessions to `pe11` (172.16.0.11), `pe12` (172.16.0.12), `bdr13` (172.16.0.13) — all on the IPv4 transport, across `ipv4 unicast`, `ipv4 vpn` and `ipv6 vpn`. `NoNeg` in a given AF's table is expected and not a fault: `pe12` doesn't activate `ipv4 unicast` and `bdr13` doesn't activate `ipv6 vpn`.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp summary"
docker exec -it clab-frr-sr-mpls-bdr13 vtysh -c "show bgp summary"
```

If any session is stuck in `Active`/`Connect`, check `update-source`/loopback reachability (Layer 2/3 must be up first — these are iBGP sessions riding the ISIS-learned loopback routes, not directly connected). Give IS-IS time to converge before concluding anything; immediately after `make lab` every session reads `Active` with `MsgRcvd 0`.

**If a session sits in `Idle` with `Connections established 0` despite loopback reachability confirmed (ping works) and OPENs actually being exchanged (`Opens: Sent N Rcvd N` both nonzero, `Notifications: Sent N Rcvd 0`)** — this isn't a reachability or capability-negotiation problem, it's `pe11`/`pe12`/`rr14` missing the `ipv6 address 2001:db8::y/128` placeholder on `lo`. All three activate `address-family ipv6 vpn`, and FRR fails the *entire* session rather than just that AF when the router has no local IPv6 address at all. Confirm via the log, which shows the exact fatal error before the `Cease`:

```shell
docker exec -it clab-frr-sr-mpls-pe11 grep -i "No local IPv6 address" /etc/frr/logs/pe11.log
```

The address only has to exist; it is unrouted and not in IS-IS.

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

Confirm the RD (`172.16.0.11:10` / `172.16.0.12:10` for RED) and RT (`65000:10`) look right, and that a label is attached to each path — for **both** AFs. The `ipv6 vpn` table being correctly populated is the point of this check: the IPv6 L3VPN control plane works end to end, and this is where you prove it.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp labelpool summary"
```

Confirms `label vpn export auto` pulled labels from the `700000–799999` dynamic block rather than failing silently.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ip route vrf RED"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show ipv6 route vrf RED"
```

**IPv4** should show the remote PE's client subnet installed with an MPLS label stack (VPN label + underlay SR label):

```
B>  10.10.2.0/30 [200/0] via 172.16.0.12 (vrf default) (recursive), label 700001
  *                        via 10.0.1.1, eth1 (vrf default), label 16112/700001, backup 0
```

**IPv6 is expected to be absent** — `show ipv6 route vrf RED` will not contain `2001:c0de:10:2::/64`, and `show bgp vrf RED ipv6 unicast` will show the path with no `*>`. This is the parked state, not a regression; see README's "IPv6 in the VRFs (6VPE)". The vpnv6 next-hop is the peer PE's unrouted `2001:db8::y` placeholder, which is deliberately not in IS-IS and therefore has no path to resolve against.

If you reinstate an IPv4-mapped (`::ffff:`) next-hop to get a resolvable one, the failure simply moves one step later — the route appears as `B>r` (rejected) with a correct-looking label stack, because the kernel cannot install an IPv6 route via an IPv4 gateway:

```shell
docker exec -it clab-frr-sr-mpls-pe11 grep -iE "Route install failed|netlink-dp.*Invalid argument" /etc/frr/logs/pe11.log
```

Either way nothing forwards. Do not spend time treating this as a configuration fault.

---

## Layer 7 — RED / BLUE dataplane (client-to-client)

| From | RED target | BLUE target |
|---|---|---|
| c1 → c2 | `10.10.2.2` / `2001:c0de:10:2::2` | `10.10.2.6` / `2001:c0de:10:4::2` |
| c2 → c1 | `10.10.1.2` / `2001:c0de:10:1::2` | `10.10.1.6` / `2001:c0de:10:3::2` |

```shell
docker exec -it clab-frr-sr-mpls-c1 ping -c 5 10.10.2.2
docker exec -it clab-frr-sr-mpls-c1 ping -c 5 10.10.2.6
docker exec -it clab-frr-sr-mpls-c2 ping -c 5 10.10.1.2
docker exec -it clab-frr-sr-mpls-c2 ping -c 5 10.10.1.6
```

All four should succeed. This is the actual end-to-end proof that SR-MPLS transport + BGP/MPLS VPN works — everything in Layers 1–6 is just confirming the plumbing behind this result.

The IPv6 equivalents are **expected to fail** with `Destination unreachable: No route`, and are worth running once so the parked state is visible rather than assumed:

```shell
docker exec -it clab-frr-sr-mpls-c1 ping6 -c 2 2001:c0de:10:2::2   # RED  — expect "No route"
docker exec -it clab-frr-sr-mpls-c1 ping6 -c 2 2001:c0de:10:4::2   # BLUE — expect "No route"
```

The IPv6 control plane is fine (Layer 6 proves it); the route cannot be installed on Linux. See README's "IPv6 in the VRFs (6VPE)".

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
```

Expect an established PCEP session to `pola` (`172.28.1.20`), sourced from `pe11`'s mgmt IP (`172.28.1.11`).

```shell
docker exec -it clab-frr-sr-mpls-pola pola session
```

Should show `pe11` as a connected PCC from the `pola` side.

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te policy"
```

Expect this to come back empty (no policies configured) until the SR-TE policy demo is rebuilt for the current topology.

### BGP-LS / TED feed — revisit checklist

The pipeline (`pe11` `mpls-te export` → zebra → BGP-LS → `gobgp` → pola) is configured and functional. It's parked because FRR 10.7.1 sends topology without SR information. Run these on revisit — each lists **what a working feed looks like** against **what 10.7.1 currently gives you**.

`gobgp` is a distroless image: use `docker exec ... /usr/local/bin/gobgp`, not a shell.

**1. Source-side export**

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show isis mpls-te database detail"
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show bgp link-state link-state"
```

| | Working | 10.7.1 |
|---|---|---|
| TED populated | 10 vertices / 17 edges / 29 subnets, with `SID:`, `Ext Admin Group:` and `Adjacency-SID:` | ✅ same — the TED is complete |
| BGP-LS table | ~50 routes ([V] node, [E] link, [T] prefix) | ✅ same |
| Registration in `rr14.log`/`pe11.log` | `Registered with Link State database` and **no** following `Failed to register` | ✅ on clean start |

**2. Collector receipt**

```shell
docker exec -it clab-frr-sr-mpls-gobgp /usr/local/bin/gobgp neighbor
docker exec -it clab-frr-sr-mpls-gobgp /usr/local/bin/gobgp global rib -a ls
docker exec -it clab-frr-sr-mpls-gobgp /usr/local/bin/gobgp global rib -a ls -j
```

| Attribute | Working | 10.7.1 |
|---|---|---|
| Session to `172.28.1.11` | Established, ~50 received | ✅ same |
| Node NLRI `sr_capabilities` | SRGB `16000:24000` | ✅ same |
| **PREFIXv4 Prefix-SID** | index present, e.g. `172.16.0.12/32` → 112 | ❌ `"prefix":{}` — empty |
| **LINK admin-group** | `0x1` on RED links, `0x2` on BLUE | ❌ absent |
| **LINK adjacency-SID** | present (matches TED `15xxx` values) | ❌ absent |
| `p5↔p6` igp_metric | `100` | ❌ `36` |
| Cross-links `p1↔p4`, `p2↔p5`, `p3↔p6` | LINK NLRIs present | ❌ absent (see below) |

The Prefix-SID row is the gate — a label is SRGB base + index, and without the index pola can't build a stack for any destination.

**3. pola ingest**

```shell
docker exec -it clab-frr-sr-mpls-pola pola ted
docker exec -it clab-frr-sr-mpls-pola pola session
```

| | Working | 10.7.1 |
|---|---|---|
| `pola ted` | full graph with per-prefix SIDs | ❌ empty |
| `pola session list` | `pe11` connected as PCC | ✅ independent of TED |

**4. The actual goal — dynamic path computation**

Only meaningful once step 2's Prefix-SID row passes. No `-s` flag, no patched binary:

```shell
docker exec -it clab-frr-sr-mpls-pola pola sr-policy add -f /pola/sr-policies/pe11-dynamic.yaml
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show sr-te policy detail"
```

```yaml
asn: 65000
srPolicy:
  pcepSessionAddr: "172.28.1.11"
  srcRouterID: "1721.6000.0011"
  dstRouterID: "1721.6000.0012"
  name: pe11-to-pe12-dynamic
  color: 100
  type: dynamic
  metric: igp
```

Working = pola computes a path and PCInitiates it to `pe11`, which appears in `show sr-te policy detail` with a resolved label stack. Note a policy does not attract traffic by itself — steering still needs `route-map ... set sr-te color` on the matching route.

**Separate TED-level gap, worth retesting at the same time**: `p1↔p4`, `p2↔p5` and `p3↔p6` are missing from `show isis mpls-te database` itself, not just BGP-LS. They're exactly the three uncoloured cross-links. Suspected cause is `admin-group-send-zero` being off by default — an uncoloured link emits no admin-group sub-TLV and apparently gets no TED edge. Perhaps colouring them a third affinity, or adding `admin-group-send-zero` under `router isis`, would confirm. This matters independently of pola since any TE computation would see the two planes as disjoint.

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
| 4 | `show isis fast-reroute summary` | non-zero LFA coverage; failover test shows the multi-label repair stack on the wire (requires stalling SPF — packet loss alone proves nothing) |
| 5 | `show bgp summary` | RR (`rr14`) sessions to `pe11`/`pe12`/`bdr13` `Established` (`NoNeg` per-AF is expected, not a fault) |
| 6 | `show bgp ipv4 vpn` / `show bgp ipv6 vpn` | RD/RT/label present both PEs, both AFs |
| 6b | `show ipv6 route vrf RED` | `2001:c0de:10:2::/64` **absent** — parked, not a regression |
| 7 | `ping` c1↔c2 RED+BLUE (IPv4) | 0% loss; IPv6 equivalents expected to fail with `No route` |
| 8 | `ping 99.99.99.99` from c3 | 0% loss |
| 9 | `show sr-te pcep session` | session to `pola` `Established` (no policy check yet — none exist) |

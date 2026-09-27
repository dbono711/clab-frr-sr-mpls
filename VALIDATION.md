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

**This grep is the actual test.** FRR silently discards unrecognized interface commands during `vtysh -b`, so a coloring mistake shows up as *nothing at all* in the running config rather than an error. If `affinity` lines are missing here but present in `frr.conf`, the syntax is being rejected — note that `isis affinity flex-algo NAME` (in FRR's current online docs) does **not** exist in 10.7.1 and will vanish exactly this way.

Then confirm they're actually **advertised** — the colouring being in the local config doesn't mean IS-IS is flooding it. The LSDB is where this is visible; `show isis interface detail` does *not* display the admin-group:

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show isis database detail" | grep -iE "Admin Group|Ext Admin Group"
```

```shell
docker exec -it clab-frr-sr-mpls-pe11 vtysh -c "show isis database json"   # extendedAdminGroup / asla per extReach entry
```

Expected values — `0x1` = RED (bit-position 0), `0x2` = BLUE (bit-position 1), advertised in both the legacy admin-group and the ASLA (`standardApp: 0x10`) encodings:

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

### Flex-Algo — not configured

There is nothing to validate here. Flex-Algo is deliberately absent from this lab: it cannot work in an `is-type level-2-only` domain on FRR 10.7.1 ([FRR #20022](https://github.com/FRRouting/frr/issues/20022), open and unfixed). It was configured, proven broken, and removed. `show isis flex-algo` will return nothing, and `show isis topology` will only ever report `"algorithm":0` — both are expected.

See README's Flex-Algo section for the intended design and the symptoms to expect if it's ever re-enabled.

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

### Observing an actual failover — you must stall SPF first

**Default reconvergence is far too fast to catch.** Everything in the repair sequence is local to the point of local repair (PLR): link-down detection is an instant carrier/admin event, backup activation is a FIB swap to an already-computed nexthop, and the PLR's SPF recomputes from its own LSDB without waiting to hear from any other node. The repair window is tens of milliseconds and typically carries **zero packets**.

That's exactly what you want operationally — but it means a naive test proves nothing. Two specific traps:

- **A 1 pps `ping` showing zero loss is not evidence of TI-LFA.** Plain SPF reconvergence in a lab this size would also drop zero packets at that rate. Both outcomes look identical.
- **Adding latency with `tc`/netem does not widen the window.** It adds *packet* latency, not *convergence* latency. It delays LSP flooding to remote nodes but changes nothing about the PLR's own detect→repair→reconverge sequence.
- Worse, `tc qdisc ... netem loss 100%` leaves the interface **UP**, so there is no link-down event, TI-LFA never activates at all, and traffic blackholes for the full IS-IS hold time (`hello 3 × holddown 10` ≈ 30s). That looks like TI-LFA failing when it was never invoked.

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
| 4 | `show isis fast-reroute summary` | non-zero LFA coverage; failover test shows the multi-label repair stack on the wire (requires stalling SPF — packet loss alone proves nothing) |
| 5 | `show bgp summary` | RR (`rr14`) sessions to `pe11`/`pe12`/`bdr13` `Established` |
| 6 | `show bgp ipv4 vpn` | RD/RT/label present both PEs |
| 7 | `ping` c1↔c2 RED+BLUE, v4+v6 | 0% loss |
| 8 | `ping 99.99.99.99` from c3 | 0% loss |
| 9 | `show sr-te pcep session` | session to `pola` `Established` (no policy check yet — none exist) |

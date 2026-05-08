# Arguments for Standardizing `numaNode` and `cpuSocketID`

> **TL;DR:** These attributes aren't competing with `pcieRoot` — they're the foundation that makes the rest of the DRA roadmap topology-aware. Every KEP the community is building (5491, 5075, 4815, 5941, 5729, 5304, 5004) works better — or in some cases only works — with standard topology attributes beyond `pcieRoot`.

---

## How the DRA Scheduler Sees Topology

DRA treats attributes as **opaque key-value pairs**. The scheduler doesn't understand what `pcieRoot` means physically. It doesn't know that `pci0000:48` and `pci0000:59` are on the same socket, or that NUMA 0 is closer to NUMA 1 than to NUMA 2. `matchAttribute` performs blind equality (or set intersection with KEP-5491) on opaque values.

The scheduler cannot derive "same socket" from "same NUMA" — it doesn't know NUMA nodes belong to sockets. It cannot derive "same NUMA" from "same pcieRoot" — it doesn't know which PCIe roots share a memory controller. **Topology intelligence lives in the attribute design and constraint composition, not in the scheduler.**

Without standardized `numaNode`, the scheduler literally cannot express "same memory controller" — not because it lacks the algorithm, but because there's no attribute to compare.

---

## The Arguments

### 1. Restores what device plugins had

DRA moved device allocation from kubelet to scheduler, breaking the topology manager's automatic NUMA coordination. Every other DRA improvement (consumable capacity, partitionable devices, list types) builds more sophisticated scheduling — but the basic "put GPU and NIC on the same NUMA" that worked with device plugins is still broken. `numaNode` is the minimum fix.

### 2. Completes the standard attribute vocabulary

`pcieRoot` is already standardized as a bus topology signal. `numaNode` adds the memory topology signal. These are genuinely orthogonal — they measure different physical properties of different hardware subsystems. A GPU and NIC can be on different PCIe switches but the same memory controller. Users compose independent constraints from both attributes based on what their workload requires:

| Attribute | Physical signal | What it answers |
|---|---|---|
| `pcieRoot` (standardized) | Bus topology | Which PCIe switch tree? |
| `numaNode` (proposed) | Memory topology | Which memory controller? |

`cpuSocketID` (physical CPU package) is a related but separate concern. Unlike pcieRoot and numaNode, which are genuinely orthogonal, `cpuSocketID` is correlated with `numaNode` — it's a coarser grouping of the same underlying physical proximity. On non-SNC hardware, socket and NUMA are equivalent. On SNC hardware, socket groups multiple NUMA nodes. You'd use `cpuSocketID` because `numaNode` is too restrictive, making it effectively a coarser variant rather than an independent signal. It is not part of the core proposal — see [Note on cpuSocketID](#note-on-cpusocketid) at the end.

### 3. Enables KEP-5491 list types to reach their potential

KEP-5491 changes `matchAttribute` to set intersection. But intersecting `pcieRoot` lists only solves CPU-to-GPU and CPU-to-NIC matching via a pivot pattern. It cannot match GPU-to-NIC directly when they're on different PCIe roots but same NUMA.

On the XE8640: GPU on `pci0000:48`, NIC on `pci0000:26`, both NUMA 0. pcieRoot intersection is empty — they're on different root complexes. To make it work, you'd need to put `pci0000:26` in the GPU's pcieRoot list — but the GPU is NOT on that root. Publishing false hardware information to make a constraint work defeats the purpose of standardized attributes.

`numaNode` as a scalar handles this with one constraint — no pivot, no transitive reasoning.

### 4. Unlocks KEP-5941 (shared consumable capacity) for topology-aware partitioning

KEP-5941 lets parent devices declare capacity consumed by children. For this to work at the NUMA level — "NUMA node 0 has 400 GB/s memory bandwidth shared across all devices" — the parent-child relationship needs a standard topology anchor. `numaNode` is that anchor. Without it, shared capacity tracking can only happen within a single driver's devices, not across drivers.

### 5. Simplifies KEP-4815 (partitionable devices) for multi-device machines

KEP-4815 partitions a single device. But machine-level partitioning ("quarter of an 8-GPU node") requires grouping devices from multiple drivers by topology. `numaNode` defines the partition boundary — all devices with `numaNode=0` form one partition group. Without it, partition builders must maintain per-driver attribute translation tables.

### 6. Makes KEP-5075 (consumable capacity) topology-aware

KEP-5075 tracks capacity consumption on shared devices. With `numaNode`, the scheduler can distinguish "this NIC on NUMA 0 has 30 Gbps remaining" from "this NIC on NUMA 1 has 100 Gbps remaining" and allocate pods accordingly. Without standardized NUMA, capacity tracking is topology-blind.

### 7. Enables KEP-5729 (per-PodGroup claims) for distributed training

Per-PodGroup ResourceClaimTemplates enable cross-pod topology constraints. "Put all 4 training pods' GPUs on the same socket" requires `cpuSocketID`. "Put each pod's GPU and NIC on the same NUMA" requires `numaNode`. Without standard topology attributes, PodGroup claims can only constrain by `pcieRoot` — which excludes 75% of GPUs on most hardware.

### 8. Critical for KEP-5304 (device metadata) consumers

KEP-5304 projects device attributes to pods as metadata files. KubeVirt's virt-launcher reads these to build guest NUMA topology (VEP 115). Today it must try 5 different attribute names:

| Driver | Attribute name | Source |
|--------|---------------|--------|
| NVIDIA GPU | `gpu.nvidia.com/numa` | `/sys/bus/pci/devices/<BDF>/numa_node` |
| AMD GPU | `gpu.amd.com/numaNode` | `/sys/bus/pci/devices/<BDF>/numa_node` |
| CPU | `dra.cpu/numaNodeID` | `/sys/devices/system/node/` |
| Memory | `dra.memory/numaNode` | NUMA zone |
| dranet | `dra.net/numaNode` | `/sys/class/net/<iface>/device/numa_node` |

One standard name means one lookup — for KubeVirt and every future metadata consumer.

### 9. Every driver already publishes the data

Five DRA drivers already read `/sys/bus/pci/devices/<BDF>/numa_node` and publish it. The implementation exists — the problem is purely naming. Standardization costs ~10 lines per driver (call the shared helper, publish under the standard name alongside the vendor name). No new sysfs reads, no new functionality.

### 10. `cpuSocketID` resolves the SNC/NPS objection that blocked `numaNode`

The reason `numaNode` was removed from KEP-4381: SNC/NPS changes NUMA IDs, potentially over-constraining on sub-NUMA hardware. `cpuSocketID` as a separate constraint about package topology addresses this — it's not a fallback from `numaNode`, it's an independent assertion about a different physical property:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  enforcement: preferred        # try same memory controller
- matchAttribute: resource.kubernetes.io/cpuSocketID
  enforcement: required         # must be same physical socket
```

If `numaNode` is too restrictive (sub-NUMA node has GPUs but no NICs), the scheduler relaxes to same socket. This directly addresses [kad's objection](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564) while preserving the value of `numaNode` for the 95% case where SNC is off.

### 11. Aligns with KEP-5004 for transparent adoption

KEP-5004 lets users write `nvidia.com/gpu: 1` without knowing DRA exists. But transparent adoption also means transparent topology — users shouldn't need to know their cluster's PCIe switch layout to get NUMA-aligned placement. `numaNode` is the user-friendly topology constraint. `pcieRoot` requires knowing hardware details. Platform admins set `numaNode` as a DeviceClass default, and every user gets topology-aware placement for free.

### 12. Proven end-to-end on real hardware

`resource.kubernetes.io/numaNode` and `cpuSocketID` have been tested across 5 DRA drivers on 3 server platforms, including KubeVirt VMs with correct guest NUMA topology built from KEP-5304 metadata:

| System | GPUs | pcieRoot GPU+NIC coverage | numaNode GPU+NIC coverage |
|--------|------|--------------------------|--------------------------|
| Dell XE8640 (H100 SXM5) | 4 | 1 of 4 (25%) | 4 of 4 (100%) |
| Dell R760xa (A40) | 2 | 0 of 2 (0%) | 2 of 2 (100%) |
| Dell XE9680 (MI300X) | 8 | 2 of 8 (25%) | 8 of 8 (100%) |

The 58% throughput improvement from NUMA-aligned placement is measured, not theoretical ([Ojea 2025](https://arxiv.org/abs/2506.23628)).

---

## The pcieRoot Gap

`pcieRoot` is the only standardized topology attribute. It fails in two critical scenarios:

**Scenario 1: GPU and NIC on different PCIe roots, same NUMA.**
On the XE8640, GPU `4e:00.0` (pcieRoot `pci0000:48`) and CX6 NIC `27:00.0` (pcieRoot `pci0000:26`) are both on NUMA 0. `matchAttribute: pcieRoot` produces an empty intersection. KEP-5491 list types don't help — neither device is on the other's root. `numaNode` matches them with one constraint.

**Scenario 2: Building KubeVirt guest NUMA topology.**
VEP 115 groups passthrough devices into guest NUMA cells. On the XE8640, NUMA 0 has devices on 4 different pcieRoot values (`pci0000:00`, `pci0000:26`, `pci0000:48`, `pci0000:59`). There's no way to reconstruct from pcieRoot alone that these 4 values all map to the same memory controller. `numaNode` directly encodes this — one attribute value per memory domain.

---

## pcieRoot and numaNode Measure Different Things

`pcieRoot` = "which PCIe switch tree is this device in?" — a **bus topology** fact.
`numaNode` = "which memory controller is closest to this device?" — a **memory topology** fact.

On simple hardware, they correlate. On real GPU servers, they diverge:

- XE8640 NUMA 0 has **four** PCIe root complexes
- XE9680 NUMA 0 has **four** PCIe root complexes
- R760xa: every device has its **own** root port

Multiple independent PCIe trees share one memory controller. [kad's objection](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564) that "NUMA doesn't represent real hardware topology" is correct for PCIe bandwidth — but `numaNode` was never meant to represent PCIe topology. It represents memory topology, which is an independently valuable and measurably impactful signal.

---

## Addressing Objections

### "NUMA doesn't represent real topology under SNC/NPS"

The sysfs value is always correct — it reports which memory controller services the device. SNC makes it finer-grained, not incorrect. GPU servers run SNC/NPS off by default. `cpuSocketID` as a required floor handles the SNC case. The attribute reports a fact; policy is the user's decision.

kad himself confirmed this semantics at [KubeCon NA 2024](https://sched.co/1i7ke): "NUMA is only about memory. There is no CPU in NUMA, there is no PCI in NUMA. Those two things are separate entities." This proposal agrees — `numaNode` measures memory controller proximity, not PCI or CPU proximity. That's what `pcieRoot` is for. Two orthogonal attributes for two separate physical properties.

**Edge case: AMD NPS4 with unpopulated memory channels.** kad noted that NPS4 with partial memory population can create NUMA nodes with CPUs but zero memory. This is a hardware configuration issue (fully populate memory channels on GPU servers), not a numaNode semantics issue.

**Forward-looking: CXL memory expanders.** CXL Type 3 devices create additional NUMA nodes not tied to any CPU socket. `numaNode` correctly handles this — the attribute reports which memory controller services the device, regardless of memory technology (DRAM, HBM, CXL).

### "pcieRoot-as-list (KEP-5491) can solve this"

For GPU+CPU and NIC+CPU co-placement via CPU-as-pivot, yes. For GPU+NIC direct matching when they're on different roots, no. For memory alignment, no — memory has no pcieRoot. For guest NUMA topology reconstruction, no — you can't derive NUMA boundaries from pcieRoot values.

### "We should only standardize attributes we all agree on"

Five drivers independently decided to publish NUMA. They just chose 5 different names. The data exists, the sysfs interface is standard Linux, the `resource.kubernetes.io/` namespace has precedent. The disagreement is about naming, not about whether the information is useful.

### "Adding more attributes increases API surface"

Each device has a 32-entry budget for attributes and capacities combined. Typical drivers use 6-10 entries. Adding 2 standard topology attributes (numaNode, cpuSocketID) uses entries the budget was designed for. The implementation is a shared helper function — drivers add one or two function calls.

---

## The Framing

`numaNode` isn't a standalone proposal. It's **enabling infrastructure for the KEPs the community is already building.** KEP-5491, 5075, 4815, 5941, 5729, 5304, and 5004 all work better with a standard memory-topology attribute beyond pcieRoot. `numaNode` isn't competing with the pcieRoot-only direction — it's the orthogonal signal that makes the rest of the DRA roadmap topology-aware. `cpuSocketID` is a separate follow-up for SNC/NPS edge cases, not part of the core proposal.

---

## Arguments Against Standardizing

The following objections have been raised in the [PR #5316 discussion](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564) and related community conversations. Each is presented with its counterargument.

### 1. NUMA doesn't represent physical topology under SNC/NPS

**The objection ([kad](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)):** "NUMA in sysfs does not represent real hardware topology in case of SNC (Intel) or NPS (AMD) active. NUMA represents only memory zone/mode of operation of Memory controller, and it has nothing to do with PCIe bandwidth or CPU core to device alignment."

With Intel SNC-2, one socket becomes 2 NUMA nodes. With AMD NPS4, one socket becomes 4. A device reporting `numaNode=0` doesn't tell you it's on the same physical silicon as `numaNode=1` — they're different memory controller partitions of the same die. Matching on `numaNode` would exclude device pairings that are physically one hop apart within the same socket.

**Counterargument:** The sysfs value is always correct — it reports which memory controller services the device. SNC makes `numaNode` finer-grained, not incorrect. GPU servers run SNC/NPS off by default — GPUs use HBM, not host DRAM, so SNC's CPU-side NUMA granularity doesn't help GPU workloads. `cpuSocketID` as a required floor handles the rare case where SNC is on and `numaNode` is too restrictive. The attribute reports a fact; policy is the user's decision.

### 2. Vendor/generation-specific meaning

**The objection:** Even within a socket, PCIe roots can have different distances to particular CPU cores depending on vendor and generation. What `numaNode=0` means on an Intel Xeon 6448Y is different from what it means on an AMD EPYC 9654. Standardizing an attribute implies its value has a consistent cross-vendor meaning — NUMA node IDs don't.

**Counterargument:** The DRA scheduler doesn't interpret attribute values — it performs blind equality matching. It doesn't need `numaNode=0` to mean the same thing across vendors. It needs two devices with `numaNode=0` on the **same node** to share a memory controller — and that's exactly what the sysfs value guarantees, regardless of vendor. NUMA node IDs are node-local, not globally meaningful.

### 3. pcieRoot already has consensus and covers the primary use case

**The objection:** The community agreed on pcieRoot. It handles the tightest co-placement (same PCIe switch), which is the most performance-critical case (GPUDirect RDMA). Adding more attributes increases API surface with diminishing returns.

**Counterargument:** pcieRoot covers Level 1 (NCCL proxy, same switch) but fails at Level 2 (training/inference, same NUMA). On the R760xa, pcieRoot is unsatisfiable for **any** GPU+NIC pair — every device has its own root port. On the XE8640 and XE9680, only 25% of GPUs share a switch with a NIC. The 58% throughput gap is between NUMA-aligned and cross-NUMA, not between same-switch and same-NUMA. pcieRoot solves the less impactful problem.

### 4. pcieRoot-as-list (KEP-5491) may solve it without new attributes

**The objection:** If CPUs publish a list of local PCIe roots and memory merges into the CPU driver, `matchAttribute: pcieRoot` with intersection semantics covers GPU + NIC + CPU + memory alignment. No new attributes needed.

**Counterargument:** This approach has five gaps:

1. **GPU and NIC can't be directly constrained.** The CPU-as-pivot pattern uses two constraints (GPU↔CPU, NIC↔CPU) that could resolve to different CPU devices on different NUMA nodes. Only a shared constraint (GPU+NIC+CPU in one `matchAttribute`) guarantees co-location — but GPU and NIC don't share a pcieRoot.
2. **Memory has no pcieRoot.** Memory is not a PCI device. The workaround is merging the memory driver into the CPU driver — a dependency on an unplanned driver merge.
3. **The CPU pcieRoot list is numaNode in disguise.** The list boundary between CPU-NUMA-0's roots and CPU-NUMA-1's roots **is** the NUMA boundary. It's a more complex encoding of the same information.
4. **Requires an alpha feature gate.** `DRAListTypeAttributes` (KEP-5491) is alpha in K8s 1.36. Building cross-driver topology on an alpha feature creates fragility.
5. **Can't reconstruct NUMA boundaries for guest topology.** KubeVirt's virt-launcher needs to group devices by memory controller to build guest NUMA cells. pcieRoot values can't be grouped without a separate lookup table mapping roots to NUMA nodes.

### 5. DRA for CPUs is questionable

**The objection ([kad](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)):** It's cheaper to migrate workloads based on actual NUMA needs than to predict and constrain at scheduling time. Inter-socket links have huge bandwidth and aren't bottlenecks for most workloads.

**Counterargument:** For general compute, this is true — cross-NUMA CPU access is fast. For GPU workloads with RDMA, it's measurably false — 58% throughput loss. DRA CPU allocation isn't about CPU-to-CPU topology; it's about pinning CPU cores to the same NUMA as the GPU so that `cudaMemcpy` and RDMA buffer staging use local memory. The topology manager did this automatically with device plugins. DRA broke it.

### 6. Drivers can publish vendor-specific attributes

**The objection:** Nothing stops a driver from publishing `gpu.nvidia.com/numaNode` today. Users who need NUMA alignment can use CEL selectors with vendor-specific names. Standardization helps cross-driver matching, but the topology coordinator solves that with attribute aliasing.

**Counterargument:** This is exactly the current state — and it doesn't work. Five drivers publish NUMA under five names. `matchAttribute` requires a common name. CEL selectors with hardcoded vendor names are fragile, non-portable, and don't work across DeviceClasses. The topology coordinator exists specifically because this approach failed. Standardization eliminates the need for translation middleware.

### 7. cpuSocketID has the same problems as numaNode

**The objection ([ffromani](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)):** "numaNode as aligning attribute has surely its share of issues, but using cpuSocket also has its share of issues, so we are swapping a problem set with another problem set." Socket-level is too coarse for intra-socket topology and doesn't account for chiplet architectures.

**Counterargument:** This is a fair point, and it's why `cpuSocketID` is not part of the core proposal. Unlike pcieRoot and numaNode, which are genuinely orthogonal (bus vs memory topology), `cpuSocketID` is correlated with `numaNode` — it's a coarser grouping of the same underlying physical proximity. On non-SNC hardware, they're equivalent. On SNC hardware, you'd use `cpuSocketID` because `numaNode` is too restrictive — making it effectively a coarser variant, not an independent signal. The recommendation is to establish `numaNode` first, then evaluate `cpuSocketID` separately if SNC-on GPU use cases emerge.

### 8. Scope creep delays DRA GA

**The objection:** The PR merged pcieRoot-only to unblock GA. Adding numaNode and cpuSocketID requires API review, naming approval, documentation, and driver adoption.

**Counterargument:** DRA GA shipped with pcieRoot-only. This proposal is for a subsequent release, not a blocker. The implementation is minimal — a shared helper function and one call per driver. The naming convention follows the existing `resource.kubernetes.io/` prefix. The API review overhead is proportional to the simplicity of the change (adding 1 well-known attribute name to a list that already has 2).

---

## Note on `cpuSocketID`

`cpuSocketID` (the physical CPU package ID) is published in our driver forks but is **not part of the core proposal**.

Unlike `pcieRoot` and `numaNode`, which are genuinely orthogonal (bus topology vs memory topology), `cpuSocketID` is correlated with `numaNode`. On non-SNC hardware (the vast majority of GPU deployments), `cpuSocketID` and `numaNode` are equivalent — one NUMA node per socket. On SNC hardware, `cpuSocketID` groups multiple NUMA nodes into a single socket. You'd use `cpuSocketID` because `numaNode` is too restrictive on SNC hardware — making it a coarser variant of the same proximity signal, not an independent physical property.

The recommended approach:

1. Establish `numaNode` as a standard attribute alongside `pcieRoot` — two orthogonal signals (memory and bus topology).
2. Recommend disabling SNC/NPS for GPU workloads (the standard GPU vendor recommendation).
3. If a strong SNC-on use case emerges where disabling SNC is not an option, propose `cpuSocketID` separately as a coarser memory-topology signal for that specific scenario.

Drivers can publish `cpuSocketID` independently as a vendor-specific attribute for deployments that need it today.

---

## References

- [KEP-4381 PR #5316](https://github.com/kubernetes/enhancements/pull/5316) — where numaNode was proposed, discussed, and deferred
- [Ojea 2025](https://arxiv.org/abs/2506.23628) — 58% throughput improvement with NUMA-aligned GPU+NIC placement
- [KEP-5491: List Types](https://github.com/kubernetes/enhancements/issues/5491) — pcieRoot-as-list approach (complementary)
- [KEP-5075: Consumable Capacity](https://github.com/kubernetes/enhancements/issues/5075) — shared device access with tracked capacity
- [KEP-4815: Partitionable Devices](https://github.com/kubernetes/enhancements/issues/4815) — dynamic GPU partitioning
- [KEP-5941: Shared Consumable Capacity](https://github.com/kubernetes/enhancements/issues/5941) — cross-device shared resource tracking
- [KEP-5729: ResourceClaim for Workloads](https://github.com/kubernetes/enhancements/issues/5729) — per-PodGroup claims
- [KEP-5304: Attributes Downward API](https://github.com/kubernetes/enhancements/issues/5304) — device metadata projection
- [KEP-5004: Extended Resources via DRA](https://github.com/kubernetes/enhancements/issues/5004) — transparent DRA adoption
- [Topology Use Cases](../topology-use-cases.md) — AI workloads mapped to topology levels
- [Topology Attribute Debate](../topology-attribute-debate.md) — full pcieRoot vs numaNode analysis
- [DRA KEP Ecosystem Overview](kep-ecosystem-overview.md) — comprehensive KEP landscape mapping

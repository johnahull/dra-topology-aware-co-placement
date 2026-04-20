# Topology Attribute Debate: numaNode vs. pcieRoot

**Date:** 2026-04-16

There is no single topology attribute that works perfectly across all hardware configurations. The upstream Kubernetes community has **active technical disagreement** about what to standardize beyond `pcieRoot`. This document covers the debate, the tradeoffs, and how each approach works in practice.

See also: [Detailed tradeoff diagrams](../testing/diagrams/topology-attribute-tradeoffs.md) for Mermaid visualizations of each scenario.

---

## Why `pcieRoot` Is Not Enough

The two standardized attributes (`pcieRoot` and `pciBusID`) are necessary for PCI device identity and same-switch grouping, but they are **insufficient for cross-device NUMA alignment** on their own. Additional topology information is needed for four reasons:

### 1. GPUs and NICs rarely share a PCIe root complex

On high-end servers, each GPU typically gets its own dedicated PCIe root complex for maximum bandwidth. On a Dell XE9680 with 8 MI300X GPUs, NUMA node 0 has:

```
NUMA node 0
├── pci0000:15  →  MI300X GPU 0
├── pci0000:37  →  MI300X GPU 1
├── pci0000:48  →  MI300X GPU 2
├── pci0000:59  →  MI300X GPU 3
└── pci0000:XX  →  ConnectX-6 NIC VFs
```

Five different PCIe root complexes on a single NUMA node. A `matchAttribute: resource.kubernetes.io/pcieRoot` constraint across GPU + NIC is **unsatisfiable** — they never share a root — even though they are on the same NUMA node and would perform well together. This was confirmed during testing ([topology coordinator issue #4](upstream-roadmap.md)).

On simpler hardware (e.g., GKE `a4-highgpu-8g` nodes with NVIDIA B200 GPUs), GPU+NIC pairs may share PCIe roots, and pcieRoot-based alignment works ([Ojea 2025](https://arxiv.org/abs/2506.23628)). But this is a hardware design choice, not a universal property.

**Update:** On this XE9680, GPU `1b:00.0` and NIC `1d:00.0` DO share a PCIe switch (both under PEX890xx on root `0000:15`). So `matchAttribute: pcieRoot` works for **that specific GPU-NIC pair**. But GPUs `3d`, `4e`, `5f` are on different switches (`0000:37`, `0000:48`, `0000:59`) with no NIC — `pcieRoot` matching fails for 3 of 4 GPUs per socket. With SNC on, the split is the same: NUMA 0 gets 1 GPU+NIC pair on `0000:15` and 1 GPU-only on `0000:59`. pcieRoot matching works for tight coupling (the GPU+NIC on the same switch) but excludes GPUs that only need NUMA-level proximity.

### 2. CPUs and memory are not PCIe devices

The CPU DRA driver and memory DRA driver do not publish `resource.kubernetes.io/pcieRoot` — CPUs and memory do not sit on a PCIe bus. Adding a pcieRoot constraint that includes CPU or memory requests makes the claim unsatisfiable ([topology coordinator issue #1](upstream-roadmap.md)).

This means pcieRoot is structurally incapable of aligning all four resource types. It can only align PCI-to-PCI devices.

**Emerging workaround: CPUs publish pcieRoot as a list.** There is a [WIP PR](https://github.com/kubernetes/kubernetes/pull/138297) by everpeace that introduces a `GetPCIeRootAttributeMapFromCPUId` helper function. It scans sysfs (`/sys/bus/pci/devices/*/local_cpulist`) to discover which PCIe root complexes are local to each CPU core, then publishes them as a list-typed attribute using KEP-5491. This would let `matchAttribute: resource.kubernetes.io/pcieRoot` work across GPU + NIC + CPU using the existing standard attribute. However, memory devices still have no PCIe root, and the approach adds complexity (scanning PCI bridges, handling bridge subclasses like InfiniBand-to-PCI).

### 3. pcieRoot is finer-grained than NUMA

pcieRoot identifies a PCIe switch. NUMA identifies a memory domain. Many pcieRoot values map to one NUMA node. Using pcieRoot for cross-device alignment **over-constrains** the problem — it asks for co-location on the same PCIe switch when all that is needed is co-location on the same memory domain.

### 4. But NUMA has its own problems

The upstream community has raised valid objections to standardizing `numaNode`: on AMD servers with NPS4 mode, a single socket has 4 NUMA nodes; on Intel with Sub-NUMA Clustering (SNC), a single socket splits into 2 or 4 NUMA domains. In these configurations, NUMA node indices from sysfs don't reflect the physical hardware topology — devices on the same socket but different NUMA nodes may still have excellent interconnect performance, and `numaNode` matching would unnecessarily exclude them.

This means there is no single topology attribute that works perfectly across all hardware configurations. The right abstraction depends on the hardware and the workload.

---

## The Upstream Debate

### Why `numaNode` was removed from KEP-4381

When [KEP-4381 PR #5316](https://github.com/kubernetes/enhancements/pull/5316) originally proposed standardizing both `pcieRoot` and `numaNode`, the `numaNode` attribute was removed after objections:

**The case against `numaNode`** ([kad](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)):
> "NUMA in sysfs does not represent real hardware topology in case of SNC (Intel) or NPS (AMD) active. NUMA represents only memory zone/mode of operation of Memory controller, and it has nothing to do with PCIe bandwidth or CPU core to device alignment."

The core issue: on AMD servers with NPS4 mode, a single socket has **4 NUMA nodes**. On Intel with Sub-NUMA Clustering (SNC), a single socket splits into **2 or 4 NUMA domains**. In these configurations, `numaNode` is finer-grained than socket — devices on the same socket but different NUMA nodes may still have excellent interconnect performance, while `numaNode` matching would exclude them.

**The case against `cpuSocketNumber`** ([fromani](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)):
> "numaNode as aligning attribute has surely its share of issues, but using cpuSocket also has its share of issues, so we are swapping a problem set with another problem set. Doesn't seem a clear improvement, rather a different tradeoff."

Even within a socket, PCIe roots may have different distances to particular CPU cores depending on the vendor and generation of hardware ([kad's KubeCon presentation](https://sched.co/1i7ke)). Socket-level alignment is coarser than what some workloads need.

**The emerging alternative: CPUs publish `pcieRoot` as a list.** Rather than introducing a new standard attribute, the community is exploring whether the CPU DRA driver can publish which PCIe root complexes each CPU core is local to, using KEP-5491 list types. everpeace has a [WIP PR](https://github.com/kubernetes/kubernetes/pull/138297) for a `GetPCIeRootAttributeMapFromCPUId` helper function. This would let `matchAttribute: resource.kubernetes.io/pcieRoot` work across GPU + NIC + CPU using the existing standard attribute — no new attribute needed.

### Current status: no consensus

Three approaches are under discussion with no resolution:

| Approach | Pros | Cons |
|---|---|---|
| Standardize `numaNode` | Matches what drivers already publish; simple mental model | Broken by SNC/NPS — doesn't reflect real topology on modern hardware |
| Standardize `cpuSocketNumber` | Meaningful on multi-socket systems | Too coarse for intra-socket topology; same objections about not reflecting real hardware |
| CPUs publish `pcieRoot` as list | Uses existing standard attribute; no new API | Complex; CPU-to-PCIe mapping is vendor-specific; memory has no pcieRoot |

### The memory gap and the CPU/memory driver merge

None of the upstream topology alignment conversations mention memory alignment. The debate is entirely focused on GPU + NIC + CPU. Memory as a fourth DRA resource type that needs NUMA alignment is not on anyone's radar.

If the community converges on pcieRoot-as-list, the memory gap depends on whether the CPU and memory drivers merge:

| Scenario | GPU+NIC+CPU alignment | Memory alignment | Need `numaNode`? |
|----------|----------------------|------------------|-------------------|
| pcieRoot-as-list, memory is separate driver | Yes (CPU-as-pivot) | No — memory has no pcieRoot | Yes |
| pcieRoot-as-list, memory merged into CPU driver | Yes (CPU-as-pivot) | Yes — same device, same pcieRoot list | No |
| Standard `numaNode` | Yes (one constraint) | Yes (one constraint) | Yes (it IS the solution) |

The CPU driver maintainer (`kad`) also maintains the memory driver, and merging them is under consideration. If that happens, pcieRoot-as-list covers all four resource types without needing `numaNode`. Without the merge, `numaNode` remains necessary for full alignment.

Even with pcieRoot-as-list covering alignment, `numaNode` is a simpler mental model: one attribute, one constraint, all drivers. pcieRoot-as-list requires the CPU-as-pivot pattern with multiple constraints — GPU and NIC don't share a pcieRoot with each other, but they each share one with the CPU, so they're *transitively* co-located on the same NUMA boundary. This indirection makes claims harder to write and debug.

---

## The SNC/NPS Problem in Detail

Sub-NUMA Clustering (Intel SNC) and NUMA Per Socket (AMD NPS) split each socket into multiple NUMA nodes. The kernel reports sub-NUMA IDs through sysfs:

| Mode | Sockets | NUMA nodes | What `numa_node=0` means |
|------|---------|------------|--------------------------|
| NPS1 | 2 | 2 | Socket 0, whole socket |
| NPS2 | 2 | 4 | Socket 0, first half |
| NPS4 | 2 | 8 | Socket 0, first quarter |
| SNC2 | 2 | 4 | Socket 0, first cluster |

### Real data: Dell XE9680 SNC on vs off

**SNC OFF (2 NUMA):**

| NUMA | CPUs | GPUs | NICs | PCIe roots |
|------|------|------|------|------------|
| 0 | 64 (even) | 4 (1b, 3d, 4e, 5f) | 2 (1d:00.0, 1d:00.1) | 0000:15, 0000:37, 0000:48, 0000:59 |
| 1 | 64 (odd) | 4 (9d, bd, cd, dd) | 2 (9f:00.0, 9f:00.1) | 0000:97, 0000:b7, 0000:c7, 0000:d7 |

**SNC ON (4 NUMA):**

| NUMA | CPUs | GPUs | NICs | PCIe roots |
|------|------|------|------|------------|
| 0 | 32 (0,4,8...) | 2 (1b, 5f) | 2 (1d:00.0, 1d:00.1) | 0000:15, 0000:59 |
| 1 | 32 (2,6,10...) | 2 (3d, 4e) | **0** | 0000:37, 0000:48 |
| 2 | 32 (1,5,9...) | 2 (9d, dd) | 2 (9f:00.0, 9f:00.1) | 0000:97, 0000:d7 |
| 3 | 32 (3,7,11...) | 2 (bd, cd) | **0** | 0000:b7, 0000:c7 |

The PCIe tree is identical in both modes — SNC only changes which CPU/memory controller services each root complex. NUMA 1 and 3 have GPUs but no NICs, creating asymmetric partitions. The topology coordinator handles this automatically. The sysfs NUMA numbers are correct in both modes.

### Getting the number is not the problem

Whether SNC or NPS, sysfs reports the correct sub-NUMA node. A device on sub-NUMA 3 correctly reports `numaNode=3`. The kubelet auto-populate approach (see [proposal](upstream-proposals/kep5304-auto-populate-metadata.md)) gives consumers the right number.

### What the number means is the problem

`numaNode=3` is meaningless without the full NUMA topology: how many sub-NUMA nodes exist, which CPUs are on each, how much memory. For KubeVirt to create a correct guest NUMA topology, it needs the shape of the host's NUMA, not just a device's node number.

### The real gap: CPU/memory placement doesn't coordinate with DRA

The core issue is that **DRA and the kubelet topology manager are separate systems**:

1. **DRA** places a device on sub-NUMA 3 (via topology coordinator CEL selectors)
2. **Kubelet topology manager** pins the pod's CPUs to sub-NUMA 0 (because it doesn't know about DRA's placement)
3. **KubeVirt** creates a guest with CPUs on NUMA 0 and a device on NUMA 3 — but the pod's cgroup only allows NUMA 0 resources

On NPS1 (2 NUMA nodes), this mostly works because each NUMA is big. On NPS4 (8 NUMA nodes), the probability of DRA and the topology manager choosing different sub-NUMAs is high.

### What each layer would need

| Layer | Difficulty | What's Needed |
|---|---|---|
| Kubelet (metadata) | Easy | Auto-populate `numaNode` from sysfs into KEP-5304 metadata for any device with `pciBusID` |
| Kubelet (topology manager + DRA coordination) | Hard | Topology manager needs to know which NUMA nodes DRA chose, and pin CPUs/memory accordingly |
| Topology Coordinator | Already handles it | Creates per-sub-NUMA partitions with per-driver CEL selectors |
| KubeVirt | Partially handled | Device-only guest NUMA cells work; CPU/memory coordination with DRA doesn't |

The topology coordinator solves the device placement problem. The kubelet auto-populate solves the metadata problem. The remaining gap is CPU/memory pinning to match DRA device placement — that requires a DRA topology hint mechanism in the kubelet, which doesn't exist today.

---

## Worked Example: pcieRoot-as-list vs. numaNode on Dell XE9680

To understand why the choice matters in practice, consider aligning GPU + NIC + CPU + memory on a 2-socket Dell XE9680 where each NUMA node has 4 GPUs, 4 NIC VFs, 64 CPUs, and ~1 TiB memory — all behind **different PCIe root complexes**.

### Approach A: `pcieRoot` as list (two constraints, CPU as pivot)

With the [WIP helper](https://github.com/kubernetes/kubernetes/pull/138297), the CPU driver publishes all local PCIe roots as a list:

```yaml
# CPU device for NUMA 0 publishes:
resource.kubernetes.io/pcieRoot: ["pci0000:15", "pci0000:37", "pci0000:48", "pci0000:59", "pci0000:XX"]

# GPU0A publishes (scalar):
resource.kubernetes.io/pcieRoot: "pci0000:15"

# NIC0 publishes (scalar):
resource.kubernetes.io/pcieRoot: "pci0000:XX"
```

A single constraint across all three fails — the GPU and NIC are on different roots, so the global intersection is empty:

```
{pci0000:15} ∩ {pci0000:XX} ∩ {pci0000:15, ..., pci0000:XX} = {}  ← unsatisfiable
```

Instead, two constraints are needed with the CPU as a **pivot device**:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, cpu]   # GPU shares a pcieRoot with CPU
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [nic, cpu]   # NIC shares a pcieRoot with CPU
```

```
Constraint 1:  GPU {pci0000:15} ∩ CPU {pci0000:15, ..., pci0000:XX} = {pci0000:15}  ✓
Constraint 2:  NIC {pci0000:XX} ∩ CPU {pci0000:15, ..., pci0000:XX} = {pci0000:XX}  ✓
```

Both constraints are satisfied by the same CPU device (NUMA 0). The GPU and NIC don't share a pcieRoot with each other, but they each share one with the CPU. Since the CPU device in grouped mode represents a NUMA node's worth of cores, the GPU and NIC are transitively co-located on the same NUMA boundary.

But memory has no pcieRoot — it's not a PCI device. Memory alignment requires falling back to `dra.net/numaNode` or CEL selectors, mixing two different alignment mechanisms in the same claim.

### Approach B: `dra.net/numaNode` (one constraint, all drivers)

```yaml
constraints:
- matchAttribute: dra.net/numaNode
  requests: [gpu, nic, cpu, mem]
```

One constraint. All four resource types. The allocator finds a NUMA node where all devices share the same value. No hardcoded NUMA IDs, no pivot device, no mixed mechanisms. This requires the AMD GPU driver to publish `dra.net/numaNode` (a one-line patch).

### Comparison

| | pcieRoot-as-list | `dra.net/numaNode` |
|---|---|---|
| GPU + NIC + CPU | ✓ (two constraints, CPU pivot) | ✓ (one constraint) |
| + Memory | ✗ (needs second mechanism) | ✓ |
| + Hugepages | ✗ (needs second mechanism) | ✓ |
| Uses standard attribute | ✓ (`resource.kubernetes.io/pcieRoot`) | ✗ (informal convention) |
| SNC/NPS correctness | ✓ (PCIe topology is physical) | ✗ (NUMA indices may not reflect real topology) |
| Claim complexity | Two+ constraints, CPU as pivot | One constraint |

### Which approach to use

| Hardware Configuration | Recommended Approach |
|---|---|
| NPS1/NPS2, no SNC (majority of AI/HPC) | `dra.net/numaNode` — simpler, covers all resource types |
| NPS4 or Intel SNC enabled | pcieRoot-as-list for PCI devices, with driver-specific NUMA handling |
| Simple PCIe topology (GPU+NIC share roots) | `resource.kubernetes.io/pcieRoot` scalar — works directly ([Ojea 2025](https://arxiv.org/abs/2506.23628)) |
| Mixed or unknown hardware | Topology coordinator — abstracts over attribute differences via ConfigMap rules |

---

## pcieRoot for Cross-Driver Matching: When It Works and When It Doesn't

Upstream is pursuing `pcieRoot` as the primary cross-driver topology attribute. This section clarifies when it works.

### Tight coupling: same-driver devices (always works)

`matchAttribute: resource.kubernetes.io/pcieRoot` across 2 GPUs ensures they're on the same PCIe switch. This is useful for GPU-GPU communication (NVLink, xGMI, peer-to-peer DMA). Every GPU has exactly one pcieRoot, and the scheduler can find groups that share one.

### Cross-driver: GPU + NIC (hardware-dependent)

On XE9680, only 1 of 4 GPUs per socket shares a PCIe switch with the NIC (GPU `1b` + NIC `1d` share root `0000:15`). The other 3 GPUs (`3d`, `4e`, `5f`) are on dedicated switches with no NIC. `matchAttribute: pcieRoot` for GPU+NIC constrains to only that 1 GPU — the other 3 are excluded even though they're on the same NUMA node and would perform fine.

On hardware where GPU and NIC share a switch (some NVIDIA DGX configs, GKE a4-highgpu), pcieRoot cross-driver matching works well.

### Loose coupling: NUMA-level alignment (pcieRoot is too specific)

For workloads that need GPU + NIC + CPU + memory on the same NUMA node — not necessarily the same PCIe switch — `pcieRoot` over-constrains. Two devices on the same NUMA but different switches can't be co-located. The pcieRoot-as-list approach (CPU publishes all local PCIe roots) works around this via the CPU-as-pivot pattern, but memory still has no pcieRoot.

### The right level depends on the use case

| Use Case | Right Attribute | Why |
|----------|----------------|-----|
| GPU-GPU peer DMA | `pcieRoot` (scalar) | Need same switch for direct transfer |
| GPU+NIC RDMA | `pcieRoot` if shared, NUMA otherwise | Same switch is ideal, same NUMA is sufficient |
| GPU+NIC+CPU+memory partition | NUMA (via coordinator or numaNode) | Need memory controller proximity, not switch proximity |
| KubeVirt guest NUMA topology | NUMA (from sysfs/KEP-5304) | Guest needs memory domain mapping, not PCIe tree |

The topology coordinator abstracts over this: it reads each driver's topology attributes via ConfigMap rules and generates the appropriate CEL selectors. It can use `pcieRoot` for tight GPU-GPU alignment and NUMA for cross-driver partitioning in the same partition config.

## Impact on This Project

The topology coordinator's ConfigMap-based attribute mapping is specifically designed to handle this uncertainty. It can map whatever attribute name each driver publishes — `dra.cpu/numaNodeID`, `gpu.amd.com/numaNode`, or a future standard — into a common topology concept. If the community eventually standardizes an attribute, the ConfigMap rules simplify but the coordinator architecture doesn't change. Meanwhile, the `dra.net/numaNode` compatibility attribute that CPU, memory, and SR-IOV drivers already publish provides a working (if informal) alignment mechanism today.

See [Topology Coordinator Design](topology-coordinator.md) for how the coordinator handles both numaNode and pcieRoot-as-list alignment modes.

---

## References

### Upstream Discussions
- [KEP-4381 PR #5316: Standard attributes](https://github.com/kubernetes/enhancements/pull/5316) — where numaNode was proposed and removed
- [kad's objection to numaNode](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)
- [fromani on numaNode vs cpuSocketNumber](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)
- [`cpuSocketNumber` standardization discussion](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)
- [kad's KubeCon presentation on PCIe topology](https://sched.co/1i7ke)

### pcieRoot-as-list Implementation
- [WIP: `GetPCIeRootAttributeMapFromCPUId` (kubernetes/kubernetes#138297)](https://github.com/kubernetes/kubernetes/pull/138297)
- [WIP: Group CPUs by PCIe root (dra-driver-cpu#68)](https://github.com/kubernetes-sigs/dra-driver-cpu/pull/68)
- [NIC/CPU alignment by pcieRoot list (dra-driver-cpu#114)](https://github.com/kubernetes-sigs/dra-driver-cpu/issues/114)
- [Original pcieRoot helper discussion (kubernetes/kubernetes#132296)](https://github.com/kubernetes/kubernetes/pull/132296#discussion_r2154600716)

### KEPs
- [KEP-5491: DRA List Types for Attributes](https://github.com/kubernetes/enhancements/issues/5491) — alpha in v1.36
- [KEP-5517: DRA for Native Resources](https://github.com/kubernetes/enhancements/pull/5755)

### Performance
- [The Kubernetes Network Driver Model (arXiv:2506.23628)](https://arxiv.org/abs/2506.23628) — 58% throughput improvement with GPU+NIC alignment

### Detailed Analysis
- [Topology Attribute Tradeoffs (diagrams)](../testing/diagrams/topology-attribute-tradeoffs.md) — Mermaid visualizations of NPS1, NPS4, SNC cases
- [NUMA/SNC/NPS Topology Gap (proposal)](upstream-proposals/numa-snc-nps-topology-gap.md) — kubelet coordination gap
- [KEP-5304 Auto-populate Metadata (proposal)](upstream-proposals/kep5304-auto-populate-metadata.md) — kubelet auto-populates NUMA from sysfs
- [Standardize numaNode with pcieRoot Fallback (proposal)](upstream-proposals/standardize-numanode-with-pcieroot-fallback.md) — formal proposal with XE9680 hardware topology data

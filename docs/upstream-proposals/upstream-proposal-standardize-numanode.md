# Upstream Proposal: Standardize `resource.kubernetes.io/numaNode`

> **TL;DR:** Standardize `resource.kubernetes.io/numaNode` (int) alongside the existing `pcieRoot`. They measure different physical properties: `pcieRoot` identifies which devices share a PCIe switch (bus topology), `numaNode` identifies which devices share a memory controller (memory topology). These are orthogonal signals — a GPU and NIC can be on different PCIe switches but the same memory controller. `numaNode` is also the missing topology anchor that KEPs 5491, 5075, and 5941 need to work across driver boundaries. One new attribute, one sysfs read, restores the cross-driver NUMA coordination that was lost when devices moved from device plugins to DRA.

---

## Problem

### Cross-driver NUMA alignment is impossible

Five DRA drivers publish NUMA node information under five different vendor-specific names:

| Driver | Attribute name | Source |
|--------|---------------|--------|
| NVIDIA GPU | `gpu.nvidia.com/numa` | `/sys/bus/pci/devices/<BDF>/numa_node` |
| AMD GPU | `gpu.amd.com/numaNode` | `/sys/bus/pci/devices/<BDF>/numa_node` |
| CPU | `dra.cpu/numaNodeID` | `/sys/devices/system/node/` |
| Memory | `dra.memory/numaNode` | NUMA zone |
| dranet (NIC) | `dra.net/numaNode` | `/sys/class/net/<iface>/device/numa_node` |

`matchAttribute` requires a common name across all devices in a constraint. Users cannot write:

```yaml
constraints:
- matchAttribute: ???/numaNode
  requests: [gpu, nic, cpu, mem]
```

There is no standard name to use. Cross-driver NUMA co-placement is impossible without middleware (topology coordinator, CEL selectors with hardcoded vendor names, or per-driver ConfigMap rules).

### Regression from device plugins

With device plugins, the kubelet's topology manager automatically coordinated CPU, memory, and device NUMA placement. A pod requesting a GPU and CPU cores got them on the same NUMA node without any user-facing constraint.

DRA moved device allocation from the kubelet to the scheduler. The topology manager has no awareness of DRA devices. There is no mechanism to co-place devices from different DRA drivers on the same NUMA node unless all drivers publish the same attribute name.

Every driver already reads NUMA from sysfs and publishes it. The data exists. The problem is purely naming — 5 drivers chose 5 different names for the same value.

### pcieRoot is the only standard topology attribute

`resource.kubernetes.io/pcieRoot` measures bus topology — which PCIe switch tree a device sits behind. This is a different physical property from memory topology — which memory controller services a device. They are orthogonal:

| Attribute | Physical signal | What it answers |
|---|---|---|
| `pcieRoot` (standardized) | Bus topology | Which PCIe switch tree? |
| `numaNode` (proposed) | Memory topology | Which memory controller? |

As [kad noted at KubeCon NA 2024](https://sched.co/1i7ke): "There is no CPU in NUMA, there is no PCI in NUMA. Those two things are separate entities." This is precisely why `numaNode` and `pcieRoot` are proposed as separate attributes — they measure different physical properties of different hardware subsystems.

---

## Why pcieRoot Alone Is Insufficient

### Most GPUs don't share a PCIe root with any NIC

On high-end GPU servers, each GPU typically gets its own dedicated PCIe root complex for maximum bandwidth. Only GPUs that share a PCIe switch with a NIC can be matched by `pcieRoot`:

| System | GPUs | pcieRoot GPU+NIC match | numaNode GPU+NIC match |
|--------|------|----------------------|----------------------|
| Dell XE8640 (4x H100 SXM5) | 4 | 1 of 4 (25%) | 4 of 4 (100%) |
| Dell R760xa (2x A40) | 2 | 0 of 2 (0%) | 2 of 2 (100%) |
| Dell XE9680 (8x MI300X) | 8 | 2 of 8 (25%) | 8 of 8 (100%) |

On the R760xa, every PCIe slot has its own root port — `matchAttribute: pcieRoot` is unsatisfiable for any GPU+NIC pair.

### CPUs and memory have no pcieRoot

CPUs and memory are not PCI devices. They have no `pcieRoot`. A `matchAttribute: pcieRoot` constraint that includes CPU or memory requests is unsatisfiable.

### KEP-5491 list types don't close the gap

KEP-5491 (alpha in K8s 1.36) enables list-typed attributes with set-intersection matching. CPUs can publish a list of local PCIe roots, enabling CPU-as-pivot matching:

```yaml
CPU:  pcieRoot: ["pci0000:48", "pci0000:59", "pci0000:26"]  # list
GPU:  pcieRoot: "pci0000:48"                                  # scalar
NIC:  pcieRoot: "pci0000:26"                                  # scalar
```

GPU↔CPU intersection: `{"pci0000:48"}` — non-empty, passes. NIC↔CPU intersection: `{"pci0000:26"}` — non-empty, passes. But GPU↔NIC intersection: `{"pci0000:48"} ∩ {"pci0000:26"} = {}` — empty, fails.

The GPU and NIC are on different PCIe roots. They share a memory controller, but pcieRoot cannot express this relationship. To make it work, you'd need to put `pci0000:26` in the GPU's pcieRoot list — but the GPU is not on that root. Publishing false hardware information to make a constraint work defeats the purpose of standardized attributes.

Additionally:
- **Memory has no pcieRoot** — the workaround requires merging the memory driver into the CPU driver, an unplanned dependency.
- **The CPU pcieRoot list is numaNode in disguise** — the list boundary between NUMA 0's roots and NUMA 1's roots IS the NUMA boundary, encoded as a more complex data structure.
- **Requires an alpha feature gate** — `DRAListTypeAttributes` can be removed or changed between releases.

### KubeVirt guest NUMA topology cannot be built from pcieRoot

KubeVirt's VEP 115 creates pxb-pcie expander bridges to place passthrough devices on the correct guest NUMA node. The virt-launcher reads device metadata (KEP-5304) to determine which guest NUMA cell each device belongs to.

With pcieRoot, every device on NUMA 0 of the XE8640 is on a different root (`pci0000:00`, `pci0000:26`, `pci0000:48`, `pci0000:59`). There is no way to reconstruct that these 4 different pcieRoot values all map to the same memory controller. `numaNode` directly encodes this — one value per memory domain.

---

## pcieRoot-Only Coverage by Use Case

| Use Case | pcieRoot only | pcieRoot + KEP-5491 lists | numaNode |
|---|---|---|---|
| NCCL proxy (GPU+NIC same switch) | Works | Works | Works |
| Training/inference (GPU+NIC+CPU same NUMA) | 0-25% GPU yield | Can't match GPU-NIC across different roots | 50-100% yield |
| Batch processing (no constraint) | Works | Works | Works |
| KubeVirt guest NUMA topology | Cannot reconstruct NUMA boundaries | Same problem | Required |

---

## Why the DRA KEP Ecosystem Needs numaNode

The DRA roadmap includes three KEPs that build sophisticated capacity and sharing semantics. Each works within a single driver, but needs a standard topology attribute to work across drivers.

**KEP-5491 (List Types, alpha in 1.36)** enables CPU-as-pivot topology matching via set intersection. But intersection operates within one attribute — it cannot derive memory proximity from bus addresses. `numaNode` is the orthogonal signal that pcieRoot, even with list types, structurally cannot express.

**KEP-5075 (Consumable Capacity, beta in 1.36)** tracks how much capacity remains on shared devices (NIC bandwidth, CPU cores). Without `numaNode`, the scheduler can't scope consumption to a topology domain — it might allocate bandwidth from a NIC on the wrong NUMA. Correct accounting, but cross-NUMA placement (58% throughput penalty).

**KEP-5941 (Shared Consumable Capacity, proposed for 1.37)** lets parent devices declare capacity consumed by children across device boundaries. For cross-driver shared capacity (NUMA node's memory bandwidth consumed by GPUs and NICs), the parent-child grouping needs a common topology anchor. `numaNode` is that anchor.

These KEPs give the scheduler **capacity awareness**. `numaNode` gives it **topology awareness**. Without both, the scheduler can track what's available but not where it should be consumed.

---

## Addressing the SNC/NPS Objection

The community [removed numaNode from KEP-4381](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564) because SNC (Intel) and NPS (AMD) change what NUMA IDs mean. As kad stated: "NUMA represents only memory zone/mode of operation of Memory controller."

### The sysfs value is always correct

SNC-2 splits each socket into 2 sub-NUMA nodes. This makes `numaNode` finer-grained, not incorrect. A device on sub-NUMA 0 correctly reports `numaNode=0` — it's on the memory controller that services that zone. The attribute reports a fact about which memory controller services the device, regardless of how many memory controllers the socket has.

### GPU servers run SNC/NPS off

GPUs use HBM, not host DRAM. SNC's finer CPU-side NUMA granularity doesn't help GPU workloads. Every GPU vendor recommends SNC off. A single required `numaNode` constraint handles all hardware with SNC off — the vast majority of GPU deployments.

### The 58% throughput difference is at the NUMA boundary

Benchmarks on NVIDIA B200 GPUs with Mellanox RoCE NICs show NUMA-aligned placement achieves 46.93 GB/s vs 29.68 GB/s unaligned — a 58% throughput improvement ([Ojea 2025](https://arxiv.org/abs/2506.23628)). This gap is between NUMA-aligned and cross-NUMA, not between same-switch and same-NUMA. The memory controller boundary is where the performance cliff occurs.

kad also noted at KubeCon NA 2024 that on modern processors (Intel 5th/6th gen Xeon, AMD EPYC), the inter-tile bus speed is "good enough" that you don't see latency differences between cores communicating with different PCI controllers on the same socket. This weakens the case for pcieRoot as the primary co-placement signal and strengthens numaNode.

### AMD NPS4 with unpopulated memory channels

On AMD platforms with NPS4 and partially populated memory channels, some NUMA nodes may have CPUs but zero memory. As kad noted: "you might end up in the Linux kernel the NUMA node which has CPUs because we split according to the CPU tiles but it has zero memory." This is a hardware configuration issue — the recommendation is to fully populate memory channels on GPU servers — not a `numaNode` semantics issue.

### CXL memory expanders

CXL Type 3 memory devices create additional NUMA nodes that don't correspond to any CPU socket. `numaNode` as defined ("which memory controller services this device") correctly handles this — a CXL-attached device reports the CXL memory controller's NUMA node. The attribute is agnostic to memory technology (DRAM, HBM, CXL).

---

## The Consumer Problem: KEP-5304 Metadata

The lack of a standard `numaNode` attribute creates a concrete problem for consumers of KEP-5304 device metadata. KubeVirt's virt-launcher reads device metadata to build guest NUMA topology (VEP 115). Today it must try multiple attribute names:

```go
for _, name := range []string{
    "resource.kubernetes.io/numaNode",
    "numaNode",
    "numa",
} {
    if attr, ok := dev.Attributes[name]; ok && attr.IntValue != nil {
        return *attr.IntValue
    }
}
```

With standardization, one lookup:

```go
numaAttr := dev.Attributes["resource.kubernetes.io/numaNode"]
```

Every future metadata consumer benefits — not just KubeVirt.

---

## What's Needed

### 1. Standardize the attribute

Add `resource.kubernetes.io/numaNode` (int) to the standard device attribute list alongside `pcieRoot` and `pciBusID`.

**Source:** `/sys/bus/pci/devices/<BDF>/numa_node` for PCI devices; `/sys/devices/system/node/node<N>/cpulist` for CPU devices; the memory controller's NUMA zone for memory devices.

**What it means:** Which memory controller services this device. Devices with the same `numaNode` share a memory controller — local DMA, no inter-controller hop.

### 2. Add helper function

In `k8s.io/dynamic-resource-allocation/deviceattribute`:

```go
func GetNUMANodeByPCIBusID(pciBusID string) (int, error)
func GetNUMANodeForCPU(cpuID int) (int, error)
```

### 3. Drivers publish the attribute

Each DRA driver adds one call to the helper function during device discovery. The sysfs read is already happening — drivers currently publish vendor-specific attributes from the same sysfs path. This standardizes the name. The implementation is ~10 lines per driver.

---

## What's Not in This Proposal

### `cpuSocketID`

Unlike `pcieRoot` and `numaNode`, which are genuinely orthogonal (bus vs memory topology), `cpuSocketID` is correlated with `numaNode` — it's a coarser grouping of the same underlying physical proximity. On non-SNC hardware, socket and NUMA are equivalent. On SNC hardware, socket groups multiple NUMA nodes. You'd use `cpuSocketID` because `numaNode` is too restrictive — making it a coarser variant, not an independent signal. It can be proposed separately if SNC-on GPU use cases emerge. Drivers can publish it as a vendor-specific attribute for deployments that need it today.

### `enforcement: preferred`

An `enforcement` field on `matchAttribute` (values: `required`, `preferred`) would allow the scheduler to try a constraint and relax if unsatisfiable. This is independently useful — it would make `pcieRoot` composable with `numaNode` on hardware like the R760xa where pcieRoot is unsatisfiable. But it is separable from this proposal. `numaNode` is valuable as a required constraint on SNC-off hardware, which covers the vast majority of GPU deployments.

---

## Example Claims

**Single-GPU inference (most common use case):**

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.nvidia.com
        count: 1
    - name: nic
      exactly:
        deviceClassName: dranet
        count: 1
    - name: cpu
      exactly:
        deviceClassName: dra.cpu
        count: 1
    constraints:
    - matchAttribute: resource.kubernetes.io/numaNode
      requests: [gpu, nic, cpu]
```

One constraint. Three drivers. All devices on the same memory controller. This is what the topology manager provided for device plugins — `numaNode` restores it for DRA.

**With pcieRoot optimization (switched hardware):**

```yaml
    constraints:
    - matchAttribute: resource.kubernetes.io/pcieRoot
      requests: [gpu, nic]
      enforcement: preferred
    - matchAttribute: resource.kubernetes.io/numaNode
      requests: [gpu, nic, cpu]
```

Two independent constraints about different physical properties. The pcieRoot constraint is an independent optimization for bus proximity — not a "tighter level" that numaNode "falls back" from. On switched hardware, both constraints are satisfied. On direct-attached hardware, pcieRoot has no effect; numaNode provides the co-placement guarantee.

---

## Evidence

Tested end-to-end on three server platforms with 5 independent DRA drivers (GPU, NIC, NVMe, CPU, memory) using `resource.kubernetes.io/numaNode`:

| System | GPUs | Topology | pcieRoot GPU+NIC | numaNode GPU+NIC |
|--------|------|----------|------------------|------------------|
| Dell XE8640 (H100 SXM5) | 4 | PCIe switches + NVLink | 1 of 4 (25%) | 4 of 4 (100%) |
| Dell R760xa (A40) | 2 | Direct-attached | 0 of 2 (0%) | 2 of 2 (100%) |
| Dell XE9680 (MI300X) | 8 | PCIe switches + xGMI | 2 of 8 (25%) | 8 of 8 (100%) |

Key results:
- 5 DRA drivers publishing `resource.kubernetes.io/numaNode` alongside vendor-specific names
- KubeVirt VMs with correct guest NUMA topology built from KEP-5304 metadata
- Multi-NUMA VMs with pxb-pcie expander bridges on correct guest NUMA cells
- 3 concurrent claims per NUMA node with per-CPU individual mode
- 58% throughput improvement from NUMA-aligned placement ([Ojea 2025](https://arxiv.org/abs/2506.23628))

---

## The PR #5316 Discussion: numaNode Was Deferred, Not Rejected

When [PR #5316](https://github.com/kubernetes/enhancements/pull/5316) originally proposed standardizing both `pcieRoot` and `numaNode`, `numaNode` was removed after debate. Key positions:

- **kad:** NUMA doesn't represent real hardware topology under SNC/NPS. Supports pcieRoot only.
- **klueska:** Only pcieRoot for now to unblock GA. Defer other attributes to separate PRs.
- **johnbelamaric:** "Yes, I would like to see some attribute upon which we can align CPU as well."
- **bg-chun:** Needs cpuSocketNumber for multi-root GPU topologies where pcieRoot can't group devices under one CPU socket.
- **ffromani:** Cautious about cpuSocketNumber — tradeoffs either way.
- **everpeace:** Proposed KEP-5491 list-typed attributes as an alternative.

The PR merged with only `pcieRoot` to unblock DRA GA — not as a technical rejection of other attributes. The conversation was explicitly deferred for separate proposals.

---

## References

- [KEP-4381 PR #5316](https://github.com/kubernetes/enhancements/pull/5316) — where numaNode was proposed, discussed, and deferred
- [Ojea 2025](https://arxiv.org/abs/2506.23628) — 58% throughput improvement with NUMA-aligned GPU+NIC placement
- [kad KubeCon NA 2024](https://sched.co/1i7ke) — "NUMA is only about memory. There is no CPU in NUMA, there is no PCI in NUMA."
- [KEP-5491: List Types](https://github.com/kubernetes/enhancements/issues/5491) — pcieRoot-as-list approach (complementary)
- [KEP-5075: Consumable Capacity](https://github.com/kubernetes/enhancements/issues/5075) — shared device access with tracked capacity
- [KEP-5941: Shared Consumable Capacity](https://github.com/kubernetes/enhancements/issues/5941) — cross-device shared resource tracking
- [KEP-5304: Attributes Downward API](https://github.com/kubernetes/enhancements/issues/5304) — device metadata projection
- [Topology Use Cases](../topology-use-cases.md) — AI workloads mapped to topology levels
- [Topology Attribute Debate](../topology-attribute-debate.md) — full pcieRoot vs numaNode analysis
- [DRA KEP Ecosystem Overview](kep-ecosystem-overview.md) — comprehensive KEP landscape mapping

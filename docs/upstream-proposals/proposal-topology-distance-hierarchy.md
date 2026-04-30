# Proposal: Standardize `numaNode` for Cross-Driver Topology Alignment in DRA

**Goal:** Restore cross-driver NUMA coordination that was lost when devices moved from the device plugin API to DRA

With device plugins, the kubelet's topology manager coordinates CPU, memory, and device placement onto the same NUMA node. When devices move to DRA, this coordination breaks — DRA allocation happens in the scheduler, and the topology manager has no awareness of DRA devices. Without a standard NUMA attribute, there is no mechanism to co-place GPUs, NICs, CPUs, and memory from different DRA drivers on the same NUMA node.

Every driver publishes NUMA under a different name (`gpu.nvidia.com/numa`, `gpu.amd.com/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode`), so `matchAttribute` can't work cross-driver. Consumers like KubeVirt's virt-launcher must hardcode every driver's naming convention or fall back to mounting host sysfs.

This proposal has two parts. Part 1 is the critical change. Part 2 is an optimization that can follow later.

---

## Part 1: Standardize `resource.kubernetes.io/numaNode` (critical)

### The problem

A user deploying an AI inference pod needs their GPU, NIC, CPU, and memory on the same NUMA node. With device plugins, the topology manager handled this automatically. With DRA, there is no way to express this — each driver publishes NUMA under a different vendor-specific name, and `matchAttribute` requires a single common name to align devices across drivers. The user cannot write a cross-driver NUMA constraint.

### The fix

Standardize `resource.kubernetes.io/numaNode` alongside `pcieRoot` and `pciBusID`. One constraint replaces the topology manager's coordination:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
```

One attribute, one constraint, four drivers. The scheduler finds a NUMA node where all resource types are available and co-locates them — the same coordination the topology manager provided for device plugins, but at the scheduler level.

### The consumer problem

The lack of a standard name also breaks consumers of KEP-5304 device metadata. KubeVirt's virt-launcher needs the NUMA node for each passthrough device to build guest topology (VEP 115 pxb-pcie placement). Today it must:

```go
// Try every driver's naming convention
numaAttr := metadata.Attributes["numaNode"]           // AMD GPU
if numaAttr == nil {
    numaAttr = metadata.Attributes["numa"]             // NVIDIA GPU
}
if numaAttr == nil {
    // fall back to host sysfs — requires /sys mount
    numa = readSysfs("/sys/bus/pci/devices/" + pciAddr + "/numa_node")
}
```

With standardization:
```go
numaAttr := metadata.Attributes["resource.kubernetes.io/numaNode"]
```

### What's needed

1. Add `resource.kubernetes.io/numaNode` (int) to the `deviceattribute` library, with a helper: `GetNUMANodeByPCIBusID(pciBusID string) (int, error)`
2. All DRA drivers publish it — one function call alongside existing `pcieRoot`

### Every driver already publishes NUMA — under different names

All DRA drivers already read NUMA from sysfs and publish it. The data exists. The problem is purely naming:

| Driver | Attribute name | Source |
|--------|---------------|--------|
| AMD GPU | `gpu.amd.com/numaNode` | `/sys/bus/pci/devices/<BDF>/numa_node` |
| NVIDIA GPU | `gpu.nvidia.com/numa` (VFIO only) | `/sys/bus/pci/devices/<BDF>/numa_node` |
| CPU | `dra.cpu/numaNodeID` | `/sys/devices/system/node/` |
| Memory | `dra.memory/numaNode` | NUMA zone |
| dranet | `dra.net/numaNode` | `/sys/class/net/<iface>/device/numa_node` |

Five drivers, five different names, same sysfs value. Standardizing `resource.kubernetes.io/numaNode` doesn't ask drivers to add new functionality — it asks them to agree on a name they already have.

### Why `pcieRoot` alone is not enough

`pcieRoot` is already standardized, but it cannot replace `numaNode` for cross-driver coordination:

**Many servers don't group devices under shared PCIe roots.** On the Dell R760xa, every PCIe slot has its own root port. Both A40 GPUs and the ConnectX-7 NIC are on NUMA 0, one root complex hop apart, but `matchAttribute: pcieRoot` fails because no two devices share a root. This is common on standard rack servers — only high-density GPU systems (XE8640, XE9680) use PCIe switches that create shared roots. A constraint that fails on standard server hardware isn't a general solution.

**`pcieRoot-as-list` ([KEP-5491](https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/5491-dra-list-types-for-attributes), alpha in K8s 1.36) requires transitive reasoning.** This approach has CPUs publish a list of local PCIe roots via the `DRAListTypeAttributes` feature gate, then match GPUs/NICs by checking if their scalar `pcieRoot` appears in the CPU's list. This requires set intersection (`is the GPU's pcieRoot in the CPU's list?`), not simple equality. `matchAttribute` does equality matching today. Supporting list intersection requires either a new constraint type or a new allocator feature — more API complexity than standardizing `numaNode`.

**`numaNode` is universal across device types.** Every PCI device has `/sys/bus/pci/devices/<BDF>/numa_node`. Every CPU has a NUMA node. Every memory zone has a NUMA node. It's the one topology concept that exists for all device types in sysfs. `pcieRoot` is PCI-specific — it works for GPUs and NICs but doesn't naturally extend to CPUs and memory without the list-typed workaround.

**Real-world examples where `pcieRoot` fails but `numaNode` works:**

- **Inference serving** — a vLLM pod needs 1 GPU + 1 NIC VF + CPU + memory on the same NUMA. On the R760xa, `pcieRoot` is unsatisfiable. `numaNode` co-locates all four resource types correctly.
- **Multi-tenant GPU hosting** — 4 independent pods on the same NUMA, each with 1 GPU + 1 SR-IOV VF. The VFs come from a NIC on a different PCIe root than the GPUs. `pcieRoot` excludes all pairings. `numaNode` matches them because they share a memory controller.
- **KubeVirt VM passthrough** — virt-launcher reads device NUMA from KEP-5304 metadata to build guest topology. With `pcieRoot`, there's no way to determine which NUMA node a device is on without falling back to sysfs. With `numaNode`, the metadata carries the answer directly.

### The SNC/NPS objection

The community removed `numaNode` from KEP-4381 because SNC/NPS changes NUMA IDs. However:
- The sysfs value is always correct — it reports which memory controller services the device
- SNC makes it finer-grained, not incorrect
- GPU servers run SNC/NPS off by default — GPUs use HBM, not host DRAM
- A single required `numaNode` constraint handles all hardware with SNC off, which is the vast majority of GPU deployments

---

## Part 2: `enforcement: preferred` on `matchAttribute` (optimization)

Add an `enforcement` field to `DeviceConstraint` with two values: `Required` (default, current behavior) and `Preferred` (scheduler tries constraint, relaxes if unsatisfiable).

This enables `pcieRoot` as a preferred constraint that falls back to `numaNode`:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred        # try same switch, accept if not
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: required         # must be same NUMA
```

**Arguments for:**
- **Portability** — one claim works on any hardware. On switched systems (XE8640, XE9680), the scheduler picks the GPU sharing a switch with the NIC. On non-switched systems (R760xa), it gracefully falls through to `numaNode`. The workload author doesn't need to know the server model.
- **Non-NCCL workloads** — custom RDMA applications, DPDK networking, or GPU-Direct Storage that don't auto-detect topology. The scheduler is their only chance at optimal placement.
- **Defense in depth** — the scheduler pre-optimizes placement instead of relying on the application to compensate.

**Arguments against:**
- **NCCL/RCCL already handle proxy selection** — both frameworks auto-detect PCIe topology and pick the best proxy GPU regardless of scheduler placement. For AI workloads, the scheduler doing it too is redundant.
- **Minimal real-world benefit** — the performance gain is one root complex hop within a NUMA node. Negligible for training (network round-trip dominates) and inference (millisecond latencies).
- **API complexity** — adding a new field to `DeviceConstraint` requires changes to all 5 K8s binaries (apiserver, scheduler, controller-manager, kubelet, kubectl).

---

## Tested on

- **Dell XE9680** (8x MI300X, ConnectX-6, K8s 1.36): 4-driver pods with GPU+NIC+CPU+memory NUMA-aligned. KubeVirt VMs with correct guest topology via pxb-pcie placement.
- **Dell R760xa** (2x NVIDIA A40, ConnectX-7, K8s 1.37-alpha): Every slot has its own root port — `pcieRoot` unsatisfiable, `numaNode` works. Demonstrates why Part 2 adds value on some hardware.
- **Dell XE8640** (4x H100 SXM5, E810 + ConnectX-6 Dx): PCIe switches group GPU+NIC+NVMe — `pcieRoot` works for NCCL proxy GPU selection.

Details: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/upstream-proposals/standardize-numanode.md
Diagrams: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/diagrams/topology-xe9680.md
Use cases: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/topology-use-cases.md

---

## Use cases

**numaNode (Part 1) — restoring topology manager coordination for DRA**
The right level for most workloads. All GPUs + NIC + CPU + memory on the same NUMA node. Training: 1 shared NIC, NCCL/RCCL proxy handles RDMA. Inference: 1 VF per pod for network isolation.

**pcieRoot preferred (Part 2) — scheduler-level PCIe switch optimization**
Optimization for systems with PCIe switches. NCCL/RCCL auto-detect this and pick the best proxy anyway — Part 2 pre-optimizes at the scheduler level. Most useful for non-NCCL workloads that don't auto-detect topology.

**No constraint — batch processing**
Throughput matters, latency doesn't. Use whatever's available.

---

**Note on `cpuSocketID`:**
`cpuSocketID` could serve as an optional fallback on SNC/NPS hardware where sub-NUMA clustering creates NUMA nodes without NICs. However, GPU servers typically run SNC/NPS off, and the recommended approach is to disable SNC for GPU workloads rather than add a scheduler fallback. `cpuSocketID` is not part of this proposal but drivers can publish it independently if needed for specific deployments.

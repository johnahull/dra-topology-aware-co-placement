# Proposal: Standardize `numaNode` and `socket` as DRA Device Attributes

> **TL;DR:** Standardize `resource.kubernetes.io/numaNode` and `resource.kubernetes.io/socket` alongside the existing `pcieRoot`. All three are hardware facts readable from sysfs. Combined with `enforcement: preferred` on `matchAttribute`, they form a distance hierarchy that handles all hardware configurations including SNC/NPS.

## Problem

DRA has one standardized topology attribute: `resource.kubernetes.io/pcieRoot`. This is insufficient for cross-driver device co-placement because:

1. **CPUs and memory are not PCI devices.** They have no `pcieRoot`. A `matchAttribute: pcieRoot` constraint that includes CPU or memory requests is unsatisfiable.

2. **pcieRoot is too restrictive for cross-device alignment.** On a Dell XE9680, only 2 of 8 GPUs share a PCIe switch with a NIC. The other 6 are on the same NUMA node but different switches — `pcieRoot` excludes them.

3. **Every driver publishes NUMA under a different name.** `gpu.nvidia.com/numa`, `gpu.amd.com/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode`, `dra.memory/numaNode`. `matchAttribute` requires a common name.

## What to Standardize

Two attributes, both derivable from sysfs on any Linux host:

### `resource.kubernetes.io/numaNode`

**Source:** `/sys/bus/pci/devices/<BDF>/numa_node` for PCI devices; `/sys/devices/system/node/node<N>/cpulist` for CPU devices; the memory controller's NUMA zone for memory devices.

**What it means:** Which memory controller services this device. Devices with the same `numaNode` share a memory controller — local DMA, no inter-controller hop.

**Type:** `int`

### `resource.kubernetes.io/socket`

**Source:** For a PCI device: read `numa_node`, find a CPU on that NUMA (`/sys/devices/system/node/node<N>/cpulist`), read that CPU's `physical_package_id` (`/sys/devices/system/cpu/cpu<X>/topology/physical_package_id`). For CPU devices: `physical_package_id` directly.

**What it means:** Which physical CPU package this device is local to. Devices with the same `socket` are within the same package's interconnect — no inter-socket link (UPI/xGMI).

**Type:** `int`

### Implementation

Both lookups belong in the shared `k8s.io/dynamic-resource-allocation/deviceattribute` package, alongside the existing `GetPCIBusIDAttribute()` and `GetPCIeRootAttributeByPCIBusID()`:

```go
func GetNUMANodeByPCIBusID(pciBusID string) (int, error) {
    // Read /sys/bus/pci/devices/<BDF>/numa_node
}

func GetSocketByPCIBusID(pciBusID string) (int, error) {
    // Read numa_node → cpulist → physical_package_id
}
```

Every DRA driver that calls `GetPCIeRootAttributeByPCIBusID()` today would add two more calls. The sysfs reads are cheap (single file read each).

## The Consumer Problem: KEP-5304 Metadata

The lack of a standard `numaNode` attribute creates a concrete problem for consumers of KEP-5304 device metadata. KubeVirt's virt-launcher reads device metadata to build guest NUMA topology (VEP 115 pxb-pcie placement). It needs the NUMA node for each passthrough device.

**Today's code** tries an unqualified `numaNode`, then falls back to sysfs:

```go
// Try KEP-5304 metadata — but what attribute name?
numaAttrName := resourcev1.QualifiedName("numaNode")
if attr, ok := device.Attributes[numaAttrName]; ok {
    return *attr.IntValue, nil
}
// Fallback: read sysfs directly
numa = readSysfs("/sys/bus/pci/devices/" + pciAddr + "/numa_node")
```

This works only if the driver publishes `numaNode` unqualified. In practice:

| Driver | What it publishes in metadata | Lookup finds it? |
|--------|------------------------------|-----------------|
| AMD GPU | `numaNode` (unqualified) | Yes |
| NVIDIA GPU | `numa` (different name) | No |
| SR-IOV NIC | nothing (no numaNode in metadata) | No → sysfs fallback |
| CPU | `dra.cpu/numaNodeID` (qualified, different name) | No |

The consumer has to either hardcode every driver's naming convention, or fall back to sysfs. The sysfs fallback works but requires the virt-launcher pod to mount `/sys` and have access to the host's PCI device tree — an unnecessary privilege escalation for what should be a metadata lookup.

**With `resource.kubernetes.io/numaNode` standardized**, every driver publishes the same attribute. One lookup, no fallback, no sysfs mount:

```go
numaAttrName := resourcev1.QualifiedName("resource.kubernetes.io/numaNode")
if attr, ok := device.Attributes[numaAttrName]; ok {
    return *attr.IntValue, nil
}
```

This isn't hypothetical — it's the current state of KubeVirt's DRA integration. The code is in [`kubevirt/kubevirt` `pkg/dra/utils.go`](https://github.com/johnahull/kubevirt/blob/feature/dra-vfio-numa-passthrough/pkg/dra/utils.go).

## The SNC/NPS Objection — and Why the Hierarchy Resolves It

The community removed `numaNode` from KEP-4381 because SNC (Intel) and NPS (AMD) change what NUMA IDs mean:

> "NUMA in sysfs does not represent real hardware topology in case of SNC or NPS active."

This is partially correct. SNC-2 splits each socket into 2 sub-NUMA nodes. A device that reports `numaNode=0` with SNC off might report `numaNode=0` or `numaNode=1` with SNC on. The number changes based on BIOS settings.

But the number is always **correct** for what it reports: which memory controller services the device. What changes is **how many memory controllers there are**, not whether the device-to-controller mapping is accurate.

The real concern is that `numaNode` matching becomes too restrictive with SNC/NPS. On the XE9680 with SNC-2:

| NUMA | GPUs | NICs |
|------|------|------|
| 0 | 2 | 2 |
| 1 | 2 | **0** |
| 2 | 2 | 2 |
| 3 | 2 | **0** |

`matchAttribute: numaNode` for GPU + NIC fails on NUMA 1 and 3 — they have no NIC. But those GPUs are on the same socket as NUMA 0 and 2, which do have NICs. Socket-level matching would work.

**The distance hierarchy resolves this.** Instead of choosing one attribute, users compose constraints:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred        # try same switch
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: preferred        # try same memory controller
- matchAttribute: resource.kubernetes.io/socket
  requests: [gpu, nic, cpu, mem]
  enforcement: required         # require same socket
```

The scheduler evaluates top to bottom:
- pcieRoot matches? Use it (tightest coupling).
- pcieRoot fails, numaNode matches? Use it (local memory, one extra PCIe hop).
- numaNode fails (SNC/NPS), socket matches? Use it (cross sub-NUMA but no inter-socket link).

No single attribute needs to handle all hardware. The hierarchy adapts.

### Dell XE9680 Match Coverage

| Attribute | GPU+NIC matched (SNC off) | GPU+NIC matched (SNC on) |
|-----------|--------------------------|--------------------------|
| pcieRoot | 2 of 8 (25%) | 2 of 8 (25%) |
| numaNode | 8 of 8 (100%) | 4 of 8 (50%) |
| socket | 8 of 8 (100%) | 8 of 8 (100%) |

### PCIe Switch to Device Mapping (SNC off)

| PCIe Root | NUMA | GPU | NIC | Shares Switch? |
|-----------|------|-----|-----|----------------|
| `pci0000:15` | 0 | `1b:00.0` | `1d:00.0`, `1d:00.1` | **Yes** |
| `pci0000:37` | 0 | `3d:00.0` | — | No |
| `pci0000:48` | 0 | `4e:00.0` | — | No |
| `pci0000:59` | 0 | `5f:00.0` | — | No |
| `pci0000:97` | 1 | `9d:00.0` | `9f:00.0`, `9f:00.1` | **Yes** |
| `pci0000:b7` | 1 | `bd:00.0` | — | No |
| `pci0000:c7` | 1 | `cd:00.0` | — | No |
| `pci0000:d7` | 1 | `dd:00.0` | — | No |

### PCIe Switch to Device Mapping (SNC on, 4 NUMA nodes)

| PCIe Root | NUMA | GPU | NIC | Coupling |
|-----------|------|-----|-----|----------|
| `pci0000:15` | 0 | `1b:00.0` | `1d:00.0`, `1d:00.1` | Tight |
| `pci0000:59` | 0 | `5f:00.0` | — | Loose |
| `pci0000:37` | 1 | `3d:00.0` | — | No NIC on NUMA |
| `pci0000:48` | 1 | `4e:00.0` | — | No NIC on NUMA |
| `pci0000:97` | 2 | `9d:00.0` | `9f:00.0`, `9f:00.1` | Tight |
| `pci0000:d7` | 2 | `dd:00.0` | — | Loose |
| `pci0000:b7` | 3 | `bd:00.0` | — | No NIC on NUMA |
| `pci0000:c7` | 3 | `cd:00.0` | — | No NIC on NUMA |

## What Upstream Needs to Change

### 1. Standardize the attributes

Add `resource.kubernetes.io/numaNode` (int) and `resource.kubernetes.io/socket` (int) to the standard device attribute list alongside `pcieRoot` and `pciBusID`.

### 2. Add helper functions

In `k8s.io/dynamic-resource-allocation/deviceattribute`:

```go
func GetNUMANodeByPCIBusID(pciBusID string) (int, error)
func GetSocketByPCIBusID(pciBusID string) (int, error)
func GetNUMANodeForCPU(cpuID int) (int, error)
func GetSocketForCPU(cpuID int) (int, error)
```

### 3. Add `enforcement: preferred` to `matchAttribute`

Today `matchAttribute` is always required. With `preferred`, the scheduler tries the constraint but relaxes if unsatisfiable. This is the key mechanism that makes the hierarchy work.

### 4. Drivers publish the attributes

Each DRA driver adds calls to the helper functions during device discovery. The sysfs reads are already happening — drivers currently publish vendor-specific attributes from the same sysfs paths. This standardizes the names.

## What This Replaces

| Current approach | Problem |
|-----------------|---------|
| Each driver publishes NUMA under its own name | `matchAttribute` can't work cross-driver |
| pcieRoot-as-list (CPU publishes local PCIe roots) | Memory has no pcieRoot; transitive reasoning required |
| Topology coordinator with ConfigMap rules | Requires middleware for basic NUMA alignment |
| No topology attribute for CPU/memory | Cross-driver alignment is impossible without driver-specific knowledge |

## What This Does NOT Replace

The topology coordinator remains valuable for:
- **Partition abstraction** — users request "an eighth of the machine" instead of writing multi-driver claims
- **Distance-based fallback** — the coordinator already implements the hierarchy pattern via `fallbackAttribute`
- **DRAConsumableCapacity** — proportional CPU/memory division across partitions
- **Per-NUMA DeviceClasses** — pre-computed resource inventories per partition

Standardizing `numaNode` and `socket` eliminates the need for the coordinator for basic NUMA alignment. The coordinator adds value at the partition abstraction layer.

## Impact on KubeVirt

The distance hierarchy applies to VMs, but KubeVirt has an additional requirement: the **guest** must see devices on the correct guest NUMA node, not just benefit from host-side placement.

### Scheduling (same as pods)

The VM's launcher pod is scheduled with the same `matchAttribute` constraints. GPU + NIC + CPU + memory land on the same host NUMA. No difference from pods.

### Guest NUMA topology (KubeVirt-specific)

KubeVirt's VEP 115 creates `pxb-pcie` expander buses to place passthrough devices on the correct guest NUMA node. The virt-launcher reads device NUMA from KEP-5304 metadata to determine which guest NUMA cell each device belongs to.

**Today**, the virt-launcher must try multiple vendor-specific attribute names:

```go
// Current: check every driver's naming convention
numaAttr := metadata.Attributes["numaNode"]           // AMD GPU
if numaAttr == nil {
    numaAttr = metadata.Attributes["numa"]             // NVIDIA GPU
}
if numaAttr == nil {
    numaAttr = metadata.Attributes["dra.net/numaNode"] // SR-IOV NIC
}
if numaAttr == nil {
    // fall back to sysfs
    numa = readSysfs("/sys/bus/pci/devices/" + pciAddr + "/numa_node")
}
```

**With standardization**, one lookup works for every driver:

```go
// Standardized: one attribute name
numaAttr := metadata.Attributes["resource.kubernetes.io/numaNode"]
```

### What the hierarchy means for guest topology

| Level | Host scheduling | Guest NUMA impact |
|-------|----------------|-------------------|
| pcieRoot | GPU + NIC on same switch | Both devices on same guest NUMA, same pxb-pcie bus |
| numaNode | GPU + NIC on same memory controller | Both devices on same guest NUMA, different pxb-pcie buses |
| socket | GPU + NIC on same package, may cross sub-NUMA | Devices may be on different guest NUMA cells within the same socket |
| node | No constraint | Guest NUMA topology may not reflect any host locality |

### CPU/memory pinning

The DRA CPU driver (`dra-driver-cpu`) handles CPU and memory pinning via NRI — it sets `cpuset.cpus` and `cpuset.mems` on the container's cgroup, pinning to the same NUMA as the DRA devices. This replaces the kubelet's built-in CPU manager; you use one or the other.

With the DRA CPU driver, the full stack works: the topology coordinator's CEL selectors place all devices on the same NUMA, and the CPU driver's NRI hook pins CPUs and memory to match. This was tested end-to-end on the XE9680 with pods and KubeVirt VMs.

For clusters that don't use the DRA CPU driver (relying on the kubelet topology manager instead), there is no coordination between DRA device placement and CPU pinning. This is an upstream gap, but it's outside the scope of this proposal — it affects any DRA deployment without the CPU driver, regardless of attribute standardization.

### Tested configurations

| Test | Host NUMAs | Guest NUMAs | Result |
|------|-----------|-------------|--------|
| Single-NUMA VM (SNC off) | GPU + NIC on NUMA 0 | 1 guest NUMA | Devices on correct guest NUMA via pxb-pcie |
| Dual-NUMA VM (SNC off) | GPU + NIC from NUMA 0 and 1 | 2 guest NUMAs (1 CPU + 1 device-only) | Correct placement, device-only cell works |
| Dual-NUMA VM (SNC on) | GPU + NIC from NUMA 0 and 2 | 2 guest NUMAs | Host NUMA 0→guest 0, host NUMA 2→guest 1 |

## Evidence

Tested on Dell XE9680 (2-socket Intel Xeon 6448Y, 8x AMD MI300X, 2x ConnectX-6 Dx) with K8s 1.36.0-rc.0:

- 4-driver pods (GPU + NIC + CPU + memory) with NUMA alignment — both SNC on and off
- Distance-based fallback producing tight and loose coupling DeviceClasses
- KubeVirt VMs with correct guest NUMA topology from DRA metadata
- Coordinator adapts automatically to SNC toggle without configuration changes

Full test results: [testing/results/results-summary.md](../../testing/results/results-summary.md)

## References

- [KEP-4381 PR #5316](https://github.com/kubernetes/enhancements/pull/5316) — where `numaNode` was proposed and removed
- [WIP: pcieRoot-as-list helper](https://github.com/kubernetes/kubernetes/pull/138297)
- [Ojea 2025](https://arxiv.org/abs/2506.23628) — 58% throughput improvement with topology-aligned GPU+NIC placement
- [Topology Attribute Debate](../topology-attribute-debate.md) — full analysis of pcieRoot vs numaNode vs socket
- [Topology Use Cases](../topology-use-cases.md) — AI workloads mapped to each distance level

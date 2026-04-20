# NUMA, SNC, and NPS: The Device Topology Gap

## The Problem

There is no standard way to communicate a device's NUMA node from a DRA driver to consumers like KubeVirt. The Kubernetes community has declined to create a standard `resource.kubernetes.io/numaNode` attribute. Each driver uses its own:

- GPU: `gpu.amd.com/numaNode` (or just `numaNode`)
- CPU: `dra.cpu/numaNodeID`
- NIC: `dra.net/numaNode`
- Memory: `dra.memory/numaNode`

Every consumer must know every driver's attribute name to find NUMA info.

## What Works Today

VEP 115 (KubeVirt's guest NUMA topology) reads NUMA from **host sysfs**: `/sys/bus/pci/devices/{addr}/numa_node`. This works because:

1. The DRA driver tells the kubelet the device's PCI address (`resource.kubernetes.io/pciBusID`)
2. The virt-launcher pod has `/sys` mounted
3. The kernel knows the correct NUMA node for every PCI device

No driver attribute agreement needed — sysfs is the source of truth.

## Proposed: Kubelet Auto-Populates NUMA in Metadata

The kubelet is the natural place to add NUMA info to KEP-5304 metadata:

1. Driver says "this device has `pciBusID = 0000:3d:02.0`"
2. Kubelet reads `/sys/bus/pci/devices/0000:3d:02.0/numa_node` → gets `0`
3. Kubelet writes `numaNode: 0` into the metadata file alongside `pciBusID`

No driver changes needed. No attribute name agreement needed. The kubelet does the lookup because it's on the host where both the PCI address and sysfs are available. Every consumer gets NUMA info automatically.

This is an enhancement to the KEP-5304 auto-populate proposal (see `kep5304-auto-populate-metadata.md`).

## The SNC/NPS Problem

Sub-NUMA Clustering (Intel SNC) and NUMA Per Socket (AMD NPS) split each socket into multiple NUMA nodes. The kernel reports sub-NUMA IDs through the same sysfs path:

| Mode | Sockets | NUMA nodes | What `numa_node=0` means |
|------|---------|------------|--------------------------|
| NPS1 | 2 | 2 | Socket 0, whole socket |
| NPS2 | 2 | 4 | Socket 0, first half |
| NPS4 | 2 | 8 | Socket 0, first quarter |
| SNC2 | 2 | 4 | Socket 0, first cluster |

The kubelet reading sysfs gives the **correct sub-NUMA ID**. The number is right. The problem is what happens next.

### Getting the Number Is Not the Problem

Whether SNC or NPS, sysfs reports the correct sub-NUMA node. The kubelet auto-populate approach gives consumers the right number. A device on sub-NUMA 3 correctly reports `numaNode=3` in the metadata.

### What the Number Means Is the Problem

`numaNode=3` is meaningless without the full NUMA topology:

- How many sub-NUMA nodes exist?
- Which CPUs are on sub-NUMA 3?
- How much memory is on sub-NUMA 3?
- Which other devices are on sub-NUMA 3?

For KubeVirt to create a correct guest NUMA topology, it needs to know the shape of the host's NUMA, not just a device's node number.

### The Real Gap: CPU/Memory Placement Doesn't Coordinate with DRA

The core issue is that **DRA and the kubelet topology manager are separate systems**:

1. **DRA** places a device on sub-NUMA 3 (via topology coordinator CEL selectors)
2. **Kubelet topology manager** pins the pod's CPUs to sub-NUMA 0 (because it doesn't know about DRA's placement)
3. **KubeVirt** creates a guest with CPUs on NUMA 0 and a device on NUMA 3 — but the pod's cgroup only allows NUMA 0 resources

On NPS1 (2 NUMA nodes), this mostly works because each NUMA is big. On NPS4 (8 NUMA nodes), the probability of DRA and the topology manager choosing different sub-NUMAs is high.

## What Each Layer Would Need

### Kubelet (metadata)

**Easy**: Auto-populate `numaNode` from sysfs into KEP-5304 metadata for any device with `pciBusID`. Works for all SNC/NPS modes — the number is always correct.

### Kubelet (topology manager + DRA coordination)

**Hard**: The topology manager needs to know which NUMA nodes DRA chose for devices, and pin CPUs and memory to the same nodes. Today these are independent systems:

- Topology manager uses topology hints from device plugins
- DRA uses ResourceClaims with CEL selectors
- Neither tells the other what it chose

A DRA topology hint mechanism would let the scheduler tell the kubelet "this pod's devices are on NUMA 0 and 3 — pin CPUs accordingly."

### Topology Coordinator

**Already handles it**: The coordinator creates per-NUMA partitions with per-driver CEL selectors. On NPS4, it would create per-sub-NUMA partitions. The coordinator reads the topology from ResourceSlices and understands SNC/NPS automatically — each sub-NUMA has its own set of devices.

### KubeVirt

**Partially handled**: Our device-only guest NUMA cell fix creates guest NUMA nodes for device NUMA nodes without vCPUs. With SNC/NPS, more guest NUMA nodes would be created. The `guestMappingPassthrough` + `pxb-pcie` mechanism works regardless of how many NUMA nodes exist.

**Gap**: KubeVirt needs the kubelet to pin CPUs/memory to the same sub-NUMA as devices. Without this, the `NUMATune` strict mode fails for device-only cells because the cgroup doesn't allow that sub-NUMA's resources.

## Real Hardware: Dell XE9680 SNC On vs Off

Tested on Dell XE9680 (2-socket Intel Sapphire Rapids, 8x MI300X GPUs, 4x ConnectX-6 ports).

### SNC OFF (2 NUMA nodes)

Each socket is one NUMA node. All PCIe root complexes on a socket share one NUMA.

| NUMA | CPUs | Memory | GPUs | NICs |
|------|------|--------|------|------|
| 0 | 64 (even: 0,2,4...) | 1 TB | 4 (1b, 3d, 4e, 5f) | 2 (1d:00.0, 1d:00.1) |
| 1 | 64 (odd: 1,3,5...) | 1 TB | 4 (9d, bd, cd, dd) | 2 (9f:00.0, 9f:00.1) |

PCIe root complexes per NUMA:
- NUMA 0: `0000:15`, `0000:37`, `0000:48`, `0000:59` (4 GPU switches + 1 NIC switch)
- NUMA 1: `0000:97`, `0000:b7`, `0000:c7`, `0000:d7` (4 GPU switches + 1 NIC switch)

### SNC ON (4 NUMA nodes)

Each socket splits into 2 sub-NUMA nodes. PCIe root complexes distribute across sub-NUMAs:

| NUMA | CPUs | Memory | GPUs | NICs |
|------|------|--------|------|------|
| 0 | 32 (0,4,8...) | 503 GB | 2 (1b, 5f) | 2 (1d:00.0, 1d:00.1) |
| 1 | 32 (2,6,10...) | 504 GB | 2 (3d, 4e) | **0** |
| 2 | 32 (1,5,9...) | 504 GB | 2 (9d, dd) | 2 (9f:00.0, 9f:00.1) |
| 3 | 32 (3,7,11...) | 504 GB | 2 (bd, cd) | **0** |

PCIe root complexes per sub-NUMA:
- NUMA 0: `0000:15`, `0000:59` (2 GPUs + NIC)
- NUMA 1: `0000:37`, `0000:48` (2 GPUs, no NIC)
- NUMA 2: `0000:97`, `0000:d7` (2 GPUs + NIC)
- NUMA 3: `0000:b7`, `0000:c7` (2 GPUs, no NIC)

### PCIe Switch to Device Mapping (SNC off)

| PCIe Root | NUMA | GPU PF | GPU VF | NIC PF | Shares Switch? | Coupling |
|-----------|------|--------|--------|--------|----------------|----------|
| `pci0000:15` | 0 | `1b:00.0` | `1b:02.0` | `1d:00.0`, `1d:00.1` | **Yes** | Tight |
| `pci0000:37` | 0 | `3d:00.0` | `3d:02.0` | — | No | Loose |
| `pci0000:48` | 0 | `4e:00.0` | `4e:02.0` | — | No | Loose |
| `pci0000:59` | 0 | `5f:00.0` | `5f:02.0` | — | No | Loose |
| `pci0000:97` | 1 | `9d:00.0` | `9d:02.0` | `9f:00.0`, `9f:00.1` | **Yes** | Tight |
| `pci0000:b7` | 1 | `bd:00.0` | `bd:02.0` | — | No | Loose |
| `pci0000:c7` | 1 | `cd:00.0` | `cd:02.0` | — | No | Loose |
| `pci0000:d7` | 1 | `dd:00.0` | `dd:02.0` | — | No | Loose |

2 of 8 GPU+NIC pairs share a PCIe switch (tight). The other 6 are on the same NUMA but different switches (loose). All 8 support GPUDirect RDMA — loose coupling adds one hop through the root complex but stays within the local memory controller.

### Key Observations

1. **PCIe tree is identical** — same physical devices, same switches. SNC only changes which CPU/memory controller services each root complex.

2. **Asymmetric device distribution** — NUMA 1 and 3 have GPUs but no NICs. The NICs share a PCIe switch with one GPU, and that switch stays on the "first half" sub-NUMA.

3. **sysfs NUMA numbers are always correct** — the kernel reports the right sub-NUMA node. No driver changes needed between SNC on/off.

4. **Topology coordinator handles both transparently** — it reads ResourceSlice attributes (which come from sysfs) and creates per-NUMA partitions. With SNC on, NUMA 1/3 get GPU-only partitions (no NICs).

5. **CPU interleaving changes** — SNC OFF: even CPUs on NUMA 0, odd on NUMA 1. SNC ON: strided across 4 nodes (0,4,8... / 2,6,10... / 1,5,9... / 3,7,11...).

## Impact on the DRA Stack

### What Works Without Changes

- **DRA drivers**: Read NUMA from sysfs, publish in ResourceSlice. Correct for any SNC/NPS mode.
- **Topology coordinator**: Creates per-NUMA partitions from ResourceSlice data. Adapts automatically to 2 vs 4 vs 8 NUMA nodes. Asymmetric partitions (GPU-only, GPU+NIC) created naturally.
- **Per-driver CEL selectors**: `device.attributes["gpu.amd.com"].numaNode == 2` works because the driver reads from sysfs.
- **KubeVirt device placement**: VEP 115 pxb-pcie reads NUMA from sysfs or KEP-5304 metadata. Correct for any topology.

### What Breaks

- **Kubelet CPU/memory pinning**: The topology manager doesn't coordinate with DRA. On SNC with 4 NUMA nodes, DRA places a device on sub-NUMA 3, but the topology manager might pin CPUs on sub-NUMA 0. The pod's cgroup doesn't allow sub-NUMA 3 resources.
- **KubeVirt guest NUMA memory binding**: Device-only guest NUMA cells need memory from the device's sub-NUMA, but the cgroup restricts it.
- **Partition symmetry assumptions**: Some workloads assume all partitions are identical. With SNC, NUMA 0 has GPU+NIC while NUMA 1 has GPU-only.

### The Fundamental Gap

DRA and the kubelet topology manager are separate systems:
- DRA knows which NUMA each device is on (from driver ResourceSlice attributes)
- Topology manager knows which NUMA each CPU/memory allocation is on (from cgroup)
- Neither tells the other what it chose

A DRA topology hint mechanism would let the scheduler tell the kubelet: "this pod's devices are on NUMA 0 and 3 — pin CPUs and memory to those nodes." This doesn't exist today.

## Summary

| Question | Status |
|----------|--------|
| Can we get the NUMA number for a device? | Yes — sysfs, always correct for SNC/NPS |
| Can the kubelet auto-populate it in metadata? | Proposed — one-time K8s change, no driver changes |
| Does the topology coordinator handle SNC/NPS? | Yes — per-sub-NUMA partitions automatically |
| Does KubeVirt guest NUMA work with SNC/NPS? | Partially — device placement works, CPU/memory coordination doesn't |
| Can DRA and topology manager coordinate? | No — this is the fundamental gap |
| Are partitions asymmetric with SNC/NPS? | Yes — NUMA 1/3 have no NICs on XE9680 |

The topology coordinator solves the device placement problem. The kubelet auto-populate solves the metadata problem. The remaining gap is CPU/memory pinning to match DRA device placement — that requires a DRA topology hint mechanism in the kubelet, which doesn't exist today.

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

## Summary

| Question | Status |
|----------|--------|
| Can we get the NUMA number for a device? | Yes — sysfs, always correct for SNC/NPS |
| Can the kubelet auto-populate it? | Proposed — one-time K8s change, no driver changes |
| Does the topology coordinator handle SNC/NPS? | Yes — per-sub-NUMA partitions automatically |
| Does KubeVirt guest NUMA work with SNC/NPS? | Partially — device placement works, CPU/memory coordination doesn't |
| Can DRA and topology manager coordinate? | No — this is the fundamental gap |

The topology coordinator solves the device placement problem. The kubelet auto-populate solves the metadata problem. The remaining gap is CPU/memory pinning to match DRA device placement — that requires a DRA topology hint mechanism in the kubelet, which doesn't exist today.

# NUMA, SNC, and NPS: The Device Topology Gap

## The Problem

DRA places devices on NUMA nodes, but the kubelet topology manager pins CPUs and memory independently. These are separate systems with no coordination — DRA may place a GPU on NUMA 0 while the topology manager pins the pod's CPUs to NUMA 1. On NPS1 (2 NUMA nodes) the odds of a mismatch are 50%. On SNC-2 or NPS4 (4-8 NUMA nodes), it's worse.

This affects any workload that combines DRA devices with dedicated CPUs: GPU training pods, inference pods, DPDK networking pods — not just VMs. KubeVirt makes the problem more visible because the guest NUMA topology exposes the mismatch directly, but a regular pod with `cpu-manager-policy: static` has the same cross-NUMA performance penalty.

Additionally, there is no standard way to communicate a device's NUMA node from a DRA driver to consumers. The Kubernetes community has declined to create a standard `resource.kubernetes.io/numaNode` attribute. Each driver uses its own:

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

### CPU/memory pinning (with DRA CPU driver)

**Solved**: The DRA CPU driver (`dra-driver-cpu`) handles CPU and memory pinning via NRI — it sets `cpuset.cpus` and `cpuset.mems` on the container's cgroup, pinning to the same NUMA as the DRA devices. The topology coordinator's CEL selectors place all device types (GPU, NIC, CPU, memory) on the same NUMA, and the CPU driver's NRI hook enforces the pinning. This replaces the kubelet's built-in CPU manager.

Tested end-to-end on the XE9680 with SNC on and off — all pods and VMs had CPUs on the correct NUMA.

### CPU/memory pinning (without DRA CPU driver)

**Gap**: Clusters using the kubelet topology manager (instead of the DRA CPU driver) have no coordination between DRA device placement and CPU pinning. The topology manager uses its own hints independently from DRA's CEL selectors. On NPS4 (8 NUMA nodes), the probability of choosing different sub-NUMAs is high. This would require a DRA topology hint mechanism in the kubelet, which doesn't exist today.

### Topology Coordinator

**Already handles device placement**: The coordinator creates per-NUMA partitions with per-driver CEL selectors. On NPS4, it would create per-sub-NUMA partitions. The coordinator reads the topology from ResourceSlices and understands SNC/NPS automatically — each sub-NUMA has its own set of devices.

### KubeVirt

**More visibly affected**: KubeVirt creates guest NUMA topology from the host pinning. A mismatch between DRA device NUMA and kubelet CPU NUMA produces a guest where the GPU is on a different NUMA node than the vCPUs — the guest OS and applications see this directly. Additionally, `NUMATune` strict mode fails for device-only NUMA cells when the cgroup doesn't allow that sub-NUMA's resources.

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

### PCIe Switch to Device Mapping (SNC on, 4 NUMA nodes)

Same physical PCIe tree, but devices now distributed across 4 sub-NUMA nodes:

| PCIe Root | NUMA | GPU PF | GPU VF | NIC PF | Shares Switch? | Coupling |
|-----------|------|--------|--------|--------|----------------|----------|
| `pci0000:15` | 0 | `1b:00.0` | `1b:02.0` | `1d:00.0`, `1d:00.1` | **Yes** | Tight |
| `pci0000:59` | 0 | `5f:00.0` | `5f:02.0` | — | No | Loose |
| `pci0000:37` | 1 | `3d:00.0` | `3d:02.0` | — | No | **No NIC on NUMA** |
| `pci0000:48` | 1 | `4e:00.0` | `4e:02.0` | — | No | **No NIC on NUMA** |
| `pci0000:97` | 2 | `9d:00.0` | `9d:02.0` | `9f:00.0`, `9f:00.1` | **Yes** | Tight |
| `pci0000:d7` | 2 | `dd:00.0` | `dd:02.0` | — | No | Loose |
| `pci0000:b7` | 3 | `bd:00.0` | `bd:02.0` | — | No | **No NIC on NUMA** |
| `pci0000:c7` | 3 | `cd:00.0` | `cd:02.0` | — | No | **No NIC on NUMA** |

SNC splits the 6 loose GPU+NIC pairs (SNC off) into two categories: 2 remain loose (same sub-NUMA as NIC, different switch) and 4 have no NIC on their sub-NUMA at all. The 2 tight pairs are unchanged — same switch, same sub-NUMA.

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

### What Breaks (without the DRA CPU driver)

- **Pods using kubelet CPU manager + DRA devices**: The kubelet topology manager doesn't coordinate with DRA. On SNC with 4 NUMA nodes, DRA places a GPU on sub-NUMA 3, but the topology manager might pin CPUs on sub-NUMA 0. Cross-NUMA GPU↔CPU communication with no error — just degraded performance.
- **KubeVirt without DRA CPU driver**: Guest sees GPU on one NUMA and vCPUs on another. Device-only guest NUMA cells need memory from the device's sub-NUMA, but the cgroup restricts it.

### What Works (with the DRA CPU driver)

- **CPU/memory pinning via NRI**: The DRA CPU driver sets `cpuset.cpus` and `cpuset.mems` via NRI, pinning to the same NUMA as DRA devices. Replaces the kubelet CPU manager.
- **KubeVirt guest NUMA**: Device-only guest NUMA cells work correctly. Tested with SNC on and off.

### Remaining Issues (regardless of CPU driver)

- **Partition symmetry assumptions**: Some workloads assume all partitions are identical. With SNC, NUMA 0 has GPU+NIC while NUMA 1 has GPU-only.

### The Remaining Gap

For clusters using the DRA CPU driver, the full stack works — device placement and CPU/memory pinning are coordinated through the topology coordinator's CEL selectors and the CPU driver's NRI hook.

For clusters using the kubelet topology manager instead, DRA and the topology manager are separate systems with no coordination. A DRA topology hint mechanism would let the scheduler tell the kubelet: "this pod's devices are on NUMA 0 and 3 — pin CPUs and memory to those nodes." This doesn't exist today, but is only relevant for deployments without the DRA CPU driver.

## Summary

| Question | Status |
|----------|--------|
| Can we get the NUMA number for a device? | Yes — sysfs, always correct for SNC/NPS |
| Can the kubelet auto-populate it in metadata? | Proposed — one-time K8s change, no driver changes |
| Does the topology coordinator handle SNC/NPS? | Yes — per-sub-NUMA partitions automatically |
| Do pods with DRA CPU driver get correct NUMA? | Yes — NRI hook pins CPUs/memory to match DRA devices |
| Do pods without DRA CPU driver get correct NUMA? | No — kubelet topology manager and DRA don't coordinate |
| Does KubeVirt guest NUMA work with SNC/NPS? | Yes (with DRA CPU driver) — tested on XE9680 SNC on/off |
| Are partitions asymmetric with SNC/NPS? | Yes — NUMA 1/3 have no NICs on XE9680 |

The topology coordinator + DRA CPU driver solve both device placement and CPU/memory pinning. The kubelet auto-populate proposal solves the metadata problem. The remaining gap — kubelet topology manager coordination with DRA — only affects clusters that don't use the DRA CPU driver.

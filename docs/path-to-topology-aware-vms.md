# The Path to Topology-Aware Device Co-Placement in KubeVirt VMs

**Date:** 2026-04-24

> **TL;DR:** Six steps — from standardized topology attributes through guest NUMA topology — to deliver end-to-end NUMA-aware GPU + NIC + CPU + memory co-placement inside KubeVirt VMs via DRA. Each step builds on the one below.

---

## Goal

Use DRA to co-place devices (GPUs, NICs, CPUs, memory) in KubeVirt VMs with full topology — so that devices on the same NUMA node, socket, or PCIe root on the host are reflected with matching topology inside the guest VM.

## Why

Without topology awareness, device assignment is random. A GPU on one side of the machine and a NIC on the other means every data transfer crosses internal bus boundaries. Benchmarks show aligned placement delivers **58% higher throughput** with near-zero variance versus unaligned ([Ojea 2025](https://arxiv.org/abs/2506.23628)). For VMs, the guest OS must also see the correct topology for AI frameworks to take advantage of it.

---

## How It Works Today

KubeVirt passthrough devices are allocated via the device plugin API. The kubelet's topology manager coordinates CPU, memory, and device plugin allocations onto the same NUMA node. VEP 115 reads each device's NUMA from host sysfs and builds matching guest topology. This works end-to-end for device-plugin devices.

## What Changes with DRA

DRA allocation happens in the scheduler, not the kubelet — the topology manager has no awareness of DRA devices. For DRA to replace the topology manager's coordination role, all four resource types (GPUs, NICs, CPUs, and memory) must be managed by DRA so they can be co-placed through a single scheduler constraint. Additionally, DRA devices bypass the device plugin API, so KubeVirt needs KEP-5304 metadata to discover their PCI addresses and NUMA placement.

DRA replaces the topology manager's coordination role for these resources. Cross-driver constraints in the scheduler (steps 1-2) co-place GPUs, NICs, CPUs, and memory on the same NUMA boundary at scheduling time. DRA does the allocation and topology decisions — KubeVirt just reads what it's given in the KEP-5304 metadata and lays out the guest topology to match.

---

## Steps Required

```
                        ┌──────────────────────────────────────┐
                        │  6. Guest NUMA Topology               │
                        ├──────────────────────────────────────┤
                        │  5. Device Metadata (KEP-5304)        │
                        ├──────────────────────────────────────┤
                        │  4. VFIO Device Passthrough via DRA   │
                        ├──────────────────────────────────────┤
                        │  3. Machine Partitioning (nice-to-have)│
                        ├──────────────────────────────────────┤
                        │  2. Topology Distance Hierarchy       │
                        ├──────────────────────────────────────┤
                        │  1. Standardized Topology Attributes  │
                        │     + Cross-Driver NUMA Alignment     │
                        └──────────────────────────────────────┘
```

---

## Step 1: Standardized Topology Attributes and Cross-Driver NUMA Alignment

### Problem

DRA drivers discover hardware devices and publish their attributes as ResourceSlices. For topology-aware placement, drivers must expose the physical location of each device — which NUMA node it's on, which PCIe root complex it's behind, and its PCI bus address.

Four DRA drivers publish topology attributes, but each uses its own attribute namespace:

| Driver | NUMA Attribute | Standard `pcieRoot` | Standard `pciBusID` |
|--------|---------------|--------------------|--------------------|
| GPU (NVIDIA) | `gpu.nvidia.com/numa` (VFIO only) | Yes | Yes (VFIO only) |
| GPU (AMD) | `gpu.amd.com/numaNode` | Yes | No (uses vendor `pciAddr`) |
| NIC (SR-IOV) | `dra.net/numaNode` | Yes | Yes |
| CPU | `dra.cpu/numaNodeID` | No (not a PCI device) | N/A |
| Memory | `dra.memory/numaNode` | No (not a PCI device) | N/A |

Only two attributes are standardized in the upstream `deviceattribute` library ([KEP-4381](https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/4381-dra-structured-parameters/README.md)):

- `resource.kubernetes.io/pcieRoot` — identifies the PCIe root complex
- `resource.kubernetes.io/pciBusID` — PCI Bus Device Function address

There is no standard `resource.kubernetes.io/numaNode`. Each driver publishes NUMA under a different vendor-specific name. DRA's `matchAttribute` constraint requires a single common name to align devices across drivers — which doesn't exist today:

```yaml
# THIS DOES NOT WORK — attribute names don't match across drivers
constraints:
- matchAttribute: ???/numaNode   # gpu.amd.com/numaNode ≠ dra.cpu/numaNodeID ≠ dra.net/numaNode
  requests: [gpu, nic, cpu, mem]
```

### Solution

Standardize `resource.kubernetes.io/numaNode` in the upstream `deviceattribute` library, following the same pattern as `pcieRoot` and `pciBusID`. With that standard attribute, cross-driver alignment becomes a single constraint:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.nvidia.com
        count: 2
    - name: nic
      exactly:
        deviceClassName: sriovnetwork
        count: 1
    - name: cpu
      exactly:
        deviceClassName: dra.cpu
        count: 1
    - name: mem
      exactly:
        deviceClassName: dra.memory
        count: 1
    constraints:
    - matchAttribute: resource.kubernetes.io/numaNode
      requests: [gpu, nic, cpu, mem]
```

One constraint, four drivers, no middleware. The scheduler finds a NUMA node where all four resource types are available and co-locates them.

For shared resources like CPU and memory, [DRAConsumableCapacity](https://github.com/kubernetes/enhancements/pull/5942) (beta in K8s 1.36) enables multiple pods to share the same CPU or memory device with divided capacity — e.g., 4 pods each getting 16 exclusive CPU cores from the same 64-core NUMA device.

### What Was Proven

All 4 drivers have been patched to publish `resource.kubernetes.io/numaNode` alongside their vendor-specific names. On the NVIDIA A40 system (Dell R760xa), a single `matchAttribute: resource.kubernetes.io/numaNode` constraint aligned GPU + NIC + CPU + memory from 4 different drivers with zero middleware.

Tested on:

- **Dell XE9680** — 8x AMD MI300X GPUs, 2x ConnectX-6 NICs, 128 CPUs, ~2 TiB RAM
- **Dell R760xa** — 2x NVIDIA A40 GPUs, ConnectX-7/6/BlueField-3 NICs, 64 CPUs

Branches: `feature/standardized-topology-attrs` on all 4 driver forks (see [Patched Repos](patched-repos.md)).
Test: `testing/scripts/demo-standardized-attrs.sh --test 3` (see [NVIDIA A40 test results](../testing/results/nvidia-a40-standardized-attrs.md)).

### What's Still Needed

- **Kubernetes upstream** — agree to standardize `resource.kubernetes.io/numaNode` in the `deviceattribute` library ([proposal](upstream-proposals/standardize-numanode.md))
- **NVIDIA GPU DRA driver** — expose NUMA for standard GPU devices (currently only published for VFIO type)
- **AMD GPU DRA driver** — publish the standard `resource.kubernetes.io/pciBusID` (currently uses vendor-specific `pciAddr`)
- **All 4 drivers** — publish standardized attributes alongside vendor-specific ones
- Without the standard attribute, cross-driver alignment requires middleware (step 3) or per-driver CEL selector workarounds

---

## Step 2: Topology Distance Hierarchy

### Problem

Not all NUMA alignment is equal. Devices can be co-located at different levels of topological tightness:

| Level | Attribute | What It Means | Coverage (XE9680) |
|-------|-----------|---------------|-------------------|
| **Tightest** | `pcieRoot` | Same PCIe switch — lowest latency, GPU-Direct RDMA | ~25% of GPU-NIC pairs |
| **Local** | `numaNode` | Same memory controller — low latency, same NUMA domain | 100% with SNC off |

On the Dell XE9680, only 1 of 4 GPUs per socket shares a PCIe switch with the NIC. The other 3 GPUs are on the same NUMA node but a different switch. Using `pcieRoot` alone excludes 75% of GPUs. Using only `numaNode` gives 100% coverage but misses the tighter coupling where it's available.

GPU servers typically run with SNC/NPS off. For the rare case where SNC is enabled, `enforcement: preferred` on `numaNode` allows the constraint to relax gracefully.

### Solution

Add an `enforcement: Preferred` field to `DeviceConstraint` in the Kubernetes API. The scheduler tries preferred constraints first but relaxes them if unsatisfiable, falling through to the next level:

```yaml
constraints:
# Try to put GPU + NIC on the same PCIe switch (tightest)
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: Preferred
# Must be on the same NUMA node (the critical boundary)
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
```

The scheduler tries pcieRoot first. If unsatisfiable (e.g., CPU doesn't publish pcieRoot, or every slot has its own root port), it relaxes to numaNode only.

### What Was Proven

Patched all 5 K8s components (apiserver, scheduler, controller-manager, kubelet, kubectl) with 3 commits to add the `Enforcement` field to `DeviceConstraint`. Tested on NVIDIA A40:

- `pcieRoot: Preferred` + `numaNode: Required` → scheduler relaxed pcieRoot (CPU doesn't publish it) while enforcing numaNode
- GPU + CPU + NIC + memory all allocated from NUMA 0
- pcieRoot relaxed, numaNode enforced

Branch: `johnahull/kubernetes` `feature/enforcement-preferred` (see [implementation details](../planning/implementation-sequence.md#phase-1b-scheduler-enforcementpreferred--done)).

### What's Still Needed

- **Kubernetes upstream** — add `enforcement: Preferred` field to `DeviceConstraint` API; covered by the same [proposal](upstream-proposals/standardize-numanode.md)
- **kube-apiserver** — accept, validate, and store the new field
- **kube-scheduler** — skip preferred constraints when unsatisfiable
- **kube-controller-manager, kubelet, kubectl** — preserve the field through the claim lifecycle

---

## Step 3: Machine Partitioning (Topology Coordinator) *(nice-to-have)*

### Problem

Even with native cross-driver alignment (steps 1-2), users must manually specify 4 driver requests, their counts, capacity requirements, and constraints. For a quarter-machine allocation on an 8-GPU node, the YAML is ~30 lines. For an eighth-machine allocation repeated 8 times, it's unmanageable.

Users want to request "a slice of the machine" — not enumerate individual drivers.

### Solution

The [topology coordinator](https://github.com/fabiendupont/k8s-dra-topology-coordinator) (POC by Fabien Dupont) is a controller + mutating webhook that:

1. **Discovers** devices from all DRA drivers via ResourceSlices
2. **Maps** vendor-specific attributes to common topology concepts via ConfigMap rules
3. **Builds** machine partitions (eighth, quarter, half, full) with proportional resource counts per NUMA node
4. **Expands** simple one-line claims into multi-driver sub-requests with NUMA constraints

```
User creates:                        Webhook expands to:
┌──────────────────────────┐         ┌─────────────────────────────────┐
│ ResourceClaim            │         │ ResourceClaim                   │
│   requests:              │         │   requests:                     │
│   - name: partition      │         │   - name: partition-gpu         │
│     deviceClassName:     │  ────>  │     count: 1                    │
│       ...-eighth         │         │   - name: partition-nic         │
│     count: 1             │         │     count: 2                    │
│                          │         │   - name: partition-cpu         │
│                          │         │     count: 1                    │
│                          │         │     capacity: {cpu: "8"}        │
│                          │         │   - name: partition-mem         │
│                          │         │     count: 1                    │
│                          │         │     capacity: {size: "8Gi"}     │
│                          │         │   constraints:                  │
│                          │         │   - matchAttribute: numaNode    │
│                          │         │     requests: [all four]        │
└──────────────────────────┘         └─────────────────────────────────┘
```

This is most useful for symmetric configurations where the machine can be evenly divided into identical partitions. This is a usability improvement — steps 1-2 provide the core alignment capability without it.

The coordinator also implements the distance hierarchy from step 2: `fallbackAttribute` on topology rules creates a pcieRoot → numaNode fallback chain, labeling each partition with its coupling level (`tight` or `local`).

### What Was Proven

On the Dell XE9680 (8x MI300X, 2x ConnectX-6, 128 CPUs, ~2 TiB RAM):

- **8 eighth-machine pods** — each with 1 GPU + 2 NICs + 8 CPU cores + memory, all NUMA-aligned
- **4 quarter-machine pods** — each with 1 GPU + 2 NICs + 16 CPU cores + 128 GiB
- **Distance-based fallback** — 2 tight partitions (GPU+NIC on same PCIe switch) + 6 local partitions (same NUMA, different switch)
- **Zero cross-NUMA contamination** in any test configuration
- **DRAConsumableCapacity** — CPU and memory shared 4 ways per NUMA with exclusive capacity

Coordinator fork: [`johnahull/k8s-dra-topology-coordinator`](https://github.com/johnahull/k8s-dra-topology-coordinator) `test/all-fixes-combined` (see [Topology Coordinator Design](topology-coordinator.md)).

### What's Still Needed

- **Topology coordinator** — merge 6 bug-fix patches (label truncation, attribute namespace, CEL selector forwarding, pcieRoot filtering, distance-based fallback)
- **Topology coordinator** — address webhook unavailability during controller restarts

---

## Step 4: VFIO Device Passthrough via DRA

### Problem

Steps 1-3 solve pod placement — containers get topology-aligned devices. But KubeVirt VMs need PCI devices passed through via VFIO, not shared. This requires:

1. Unbinding the device from its native kernel driver (e.g., `amdgpu`)
2. Binding it to the `vfio-pci` driver
3. Exposing `/dev/vfio/*` device nodes to the container
4. Managing IOMMU groups correctly

### Solution

DRA drivers manage the full VFIO lifecycle:

**NVIDIA GPU DRA driver** — has `type: vfio` support behind the `PassthroughSupport` feature gate. The DeviceClass specifies VFIO mode, and the driver handles bind/unbind, CDI specs, and IOMMU groups.

**AMD GPU DRA driver** — needed patches to add VFIO support:

- `GpuConfig.Driver = "vfio-pci"` triggers VFIO mode
- `applyVFIOConfig()` unbinds from `amdgpu`, binds to `vfio-pci` via `driver_override`
- `getIOMMUGroup()` reads IOMMU group from sysfs
- CDI specs include `/dev/vfio/vfio` + `/dev/vfio/<group>` devices
- Common CDI device (`/dev/kfd`) skipped in VFIO mode (not available after unbind)

**SR-IOV NIC driver** — VFs can be pre-bound to `vfio-pci` or bound at prepare time. Additional patches needed to skip CNI/RDMA handling for VFIO-bound VFs.

### What Was Proven

On the Dell XE9680:

- AMD MI300X GPU VFs bound to `vfio-pci` via DRA driver, CDI specs generated correctly
- ConnectX-6 NIC VFs bound to `vfio-pci`, IOMMU groups correct
- Both device types passed through to KubeVirt VMs as `<hostdev>` in libvirt domain XML

Branches: `johnahull/k8s-gpu-dra-driver` `feature/vfio-passthrough` (see [Patched Repos](patched-repos.md)).

### What's Still Needed

- **AMD GPU DRA driver** — add VFIO bind/unbind lifecycle and CDI device generation; fix GPU discovery after VFIO unbind
- **SR-IOV NIC DRA driver** — add formal VFIO mode (skip CNI/RDMA for VFIO-bound VFs)
- **NVIDIA GPU DRA driver** — has `type: vfio` support behind the `PassthroughSupport` feature gate

---

## Step 5: Device Metadata (KEP-5304)

### Problem

After VFIO passthrough (step 4), the KubeVirt virt-launcher needs two pieces of information about each allocated device:

1. **PCI bus address** (pciBusID) — to create the correct `<hostdev>` entry in libvirt domain XML
2. **NUMA node** — to place the device on the correct guest NUMA node (step 6)

But DRA allocation results only contain device names (e.g., `gpu-9`, `0000-1d-00-2`). The PCI address and topology attributes are in the ResourceSlice, not in the allocation result.

### Solution

KEP-5304 (native in K8s 1.36) is a Kubernetes API that lets DRA drivers attach metadata (key-value attributes) to allocated devices. When a device is prepared, the driver publishes attributes like PCI address and NUMA node. The kubelet writes these as JSON files and mounts them into the pod at a well-known path. Virt-launcher reads the PCI address to create VFIO passthrough entries in the VM's domain XML, and reads the NUMA node to place each device on the correct guest NUMA node.

Drivers opt in with `EnableDeviceMetadata(true)` in the kubelet plugin helper:

```
/var/run/kubernetes.io/dra-device-attributes/resourceclaims/<claim>/<request>/<driver>-metadata.json
```

Example metadata file:

```json
{
  "requests": [{
    "name": "gpu",
    "devices": [{
      "driver": "gpu.amd.com",
      "attributes": {
        "resource.kubernetes.io/pciBusID": {"string": "0000:3d:02.0"},
        "numaNode": {"int": 0},
        "productName": {"string": "MI300X"}
      }
    }]
  }]
}
```

### What Was Proven

- AMD GPU and SR-IOV NIC drivers patched to publish KEP-5304 metadata
- virt-launcher reads `pciBusID` to create `<hostdev>` entries
- virt-launcher reads `numaNode` to determine guest NUMA placement
- Sysfs fallback for drivers that don't publish `numaNode` in metadata

### What's Still Needed

- **Kubernetes kubelet** — fix bug where multi-driver claims only inject metadata for one driver
- **AMD GPU DRA driver** — opt in to KEP-5304 and publish standard `resource.kubernetes.io/pciBusID`
- **SR-IOV NIC DRA driver** — opt in to KEP-5304 and publish device metadata
- **NVIDIA GPU DRA driver** — KEP-5304 opt-in in progress (issue #916, targeting v26.4.0)

---

## Step 6: Guest NUMA Topology

### Problem

With steps 1-5, the host-side placement is correct — devices are VFIO-bound on the right NUMA nodes with metadata available. But QEMU creates its own virtual NUMA topology. The guest OS has its own `/sys/bus/pci/devices/*/numa_node` values. Without explicit configuration, guest devices show `numa_node=-1` and AI frameworks can't detect co-locality.

KubeVirt's `guestMappingPassthrough` ([VEP 115](https://github.com/kubevirt/community/pull/303)) creates guest NUMA topology from the kubelet's CPU placement — not DRA device placement. It reads device NUMA from host sysfs for device-plugin devices, but has no path to get NUMA for DRA devices.

### Solution

Patched virt-launcher to bridge DRA device metadata into guest NUMA topology:

1. **Read KEP-5304 metadata** — `buildDRANUMAOverrides()` reads `numaNode` for each DRA host device, with sysfs fallback for drivers that don't publish it
2. **Place pxb-pcie buses** — VEP 115 `pxb-pcie` expander buses are placed on the correct guest NUMA node using DRA NUMA overrides
3. **Transform host→guest NUMA IDs** — `transformDRAOverridesToGuestCells()` maps host NUMA node numbers to sequential guest cell IDs

The result is a guest PCI topology that mirrors the host device placement:

```
Guest PCI Topology:
  pxb-pcie NUMA 0:
    GPU VF 0000:3d:02.0  →  guest numa_node=0
    NIC VF 0000:1d:01.1  →  guest numa_node=0
  pxb-pcie NUMA 1:
    GPU VF 0000:9d:02.0  →  guest numa_node=1
    NIC VF 0000:9f:00.2  →  guest numa_node=1
```

### What Was Proven

On the Dell XE9680 with KubeVirt v1.8.1 (patched):

**Single-NUMA VM** (1 GPU + 1 NIC from NUMA 0):
- KEP-5304 metadata provides PCI address + NUMA node
- pxb-pcie expander on guest NUMA 0 hosts both devices
- VM boots Fedora 41

**Dual-NUMA VM** (1 GPU + 1 NIC from each NUMA node):
- Two pxb-pcie expanders, one per guest NUMA node
- Guest NUMA 0: vCPUs + GPU + NIC
- Guest NUMA 1: GPU + NIC
- Guest `numactl --hardware` shows 2 NUMA nodes with correct device placement

```
# Inside the guest VM:
$ for d in /sys/bus/pci/devices/*/numa_node; do
    dev=$(basename $(dirname $d)); node=$(cat $d)
    [ "$node" != "-1" ] && echo "$dev: numa=$node"
  done
0000:fb:00.0: numa=1  # NIC VF (ConnectX-6, NUMA 1)
0000:fc:00.0: numa=1  # GPU VF (MI300X, NUMA 1)
0000:fe:00.0: numa=0  # NIC VF (ConnectX-6, NUMA 0)
0000:ff:00.0: numa=0  # GPU VF (MI300X, NUMA 0)
```

KubeVirt patches: [`johnahull/kubevirt`](https://github.com/johnahull/kubevirt) `feature/dra-vfio-numa-passthrough` — 12 files across virt-controller + virt-launcher (see [KubeVirt Integration](kubevirt-integration.md)).

### What's Still Needed

- **KubeVirt virt-launcher** — read DRA device NUMA from KEP-5304 metadata in VEP 115 (currently only reads sysfs for device-plugin devices)
- **KubeVirt virt-controller** — add VFIO capabilities (SYS_RESOURCE, IPC_LOCK, unlimited memlock) for DRA host device pods
- **KubeVirt virt-controller** — skip `permittedHostDevices` validation for DRA-allocated devices (partially addressed upstream with `HostDevicesWithDRA` feature gate)
- **KubeVirt** — auto-enable ACPI when guest NUMA topology is used

---

## The Full Chain

From driver discovery to guest NUMA topology, the complete data flow:

```
1. DRA drivers read sysfs and publish standardized topology attributes
   └── GPU: /sys/bus/pci/devices/<BDF>/numa_node → resource.kubernetes.io/numaNode
   └── NIC: /sys/class/net/<iface>/device/numa_node → resource.kubernetes.io/numaNode
   └── CPU: /sys/devices/system/node/node*/cpulist → resource.kubernetes.io/numaNode
   └── Memory: /sys/devices/system/node/node*/meminfo → resource.kubernetes.io/numaNode
   └── matchAttribute: resource.kubernetes.io/numaNode aligns all 4 drivers

2. Scheduler applies distance hierarchy
   └── enforcement: Preferred on pcieRoot → numaNode required

3. Topology coordinator creates partition DeviceClasses (nice-to-have)
   └── User requests "eighth" → webhook expands to 4 sub-requests + constraints

4. DRA drivers prepare VFIO devices
   └── Unbind from native driver → bind to vfio-pci → CDI specs for /dev/vfio/*

5. Drivers publish KEP-5304 metadata
   └── pciBusID + numaNode → JSON files mounted at /var/run/kubernetes.io/dra-device-attributes/

6. KubeVirt virt-launcher reads metadata and builds guest topology
   └── pciBusID → <hostdev> in domain XML
   └── numaNode → pxb-pcie expander bus → guest NUMA cell
   └── Guest OS sees correct topology → AI frameworks detect GPU-NIC co-locality
```

---

## Current State

All 6 steps have been proven end-to-end on real hardware with local patches:

- **Dell R760xa** (active, 2026-04-28): KubeVirt VM running with `guestMappingPassthrough`, GPU VFIO passthrough, and DRA-aware CPU pinning. The kubelet's DRA Manager implements `topologymanager.HintProvider` — reads `resource.kubernetes.io/numaNode` from ResourceSlice device attributes, returns NUMA topology hints, and the CPU manager pins vCPUs to the same NUMA node as the DRA-allocated GPU. Guest sees correct single-NUMA topology with A40 GPU at 0000:09:00.0. All devices allocated via DRA (GPU, NIC via dranet, CPU, memory). See [Setup Guide](dra-topology-aware-vm-setup.md).
- **Dell XE9680** (2026-04-24): 8-GPU topology coordinator tests, SNC on/off comparison, multi-NUMA VMs with AMD MI300X. Original proof-of-concept system.

---

## References

- [KEP-4381: DRA Structured Parameters](https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/4381-dra-structured-parameters/README.md)
- [KEP-5304: Native Device Metadata API](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5304-dra-with-dra-driver-device-metadata)
- [KEP-5491: List Types for Attributes](https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/5491-dra-list-types-for-attributes) (alpha in v1.36)
- [VEP 115: PCI NUMA-Aware Topology](https://github.com/kubevirt/community/pull/303)
- [The Kubernetes Network Driver Model (Ojea 2025)](https://arxiv.org/abs/2506.23628)
- [Project Narrative](project-narrative.md) — 3-story structure
- [Gap Analysis](gap-analysis.md) — 8 specific gaps, driver comparison
- [Architecture](architecture.md) — component diagrams, allocation flows
- [Topology Coordinator Design](topology-coordinator.md) — partition builder, webhook expansion
- [KubeVirt Integration](kubevirt-integration.md) — KEP-5304, VEP 115, VFIO details
- [Upstream Roadmap](upstream-roadmap.md) — complete patch inventory
- [Patched Repos](patched-repos.md) — all forks and branches
- [Test Results Summary](../testing/results/results-summary.md) — test matrix, hardware captures

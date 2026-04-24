# Topology-Aware Device Co-Placement in KubeVirt VMs

**Date:** 2026-04-24

## Goal

Use DRA to co-place devices (GPUs, NICs, CPUs, memory) in KubeVirt VMs with full topology — so that devices on the same NUMA node, socket, or PCIe root on the host are reflected with matching topology inside the guest VM.

## Why

Without topology awareness, device assignment is random. A GPU on one side of the machine and a NIC on the other means every data transfer crosses internal bus boundaries. Benchmarks show aligned placement delivers **58% higher throughput** with near-zero variance versus unaligned ([Ojea 2025](https://arxiv.org/abs/2506.23628)). For VMs, the guest OS must also see the correct topology for AI frameworks to take advantage of it.

## How It Works Today

KubeVirt passthrough devices are allocated via the device plugin API. The kubelet's topology manager coordinates CPU, memory, and device plugin allocations onto the same NUMA node. VEP 115 reads each device's NUMA from host sysfs and builds matching guest topology. This works end-to-end for device-plugin devices.

## What Changes with DRA

DRA allocation happens in the scheduler, not the kubelet — the topology manager has no awareness of DRA devices. For DRA to replace the topology manager's coordination role, all four resource types (GPUs, NICs, CPUs, and memory) must be managed by DRA so they can be co-placed through a single scheduler constraint. Additionally, DRA devices bypass the device plugin API, so KubeVirt needs KEP-5304 metadata to discover their PCI addresses and NUMA placement.

DRA replaces the topology manager's coordination role for these resources. Cross-driver constraints in the scheduler (steps 1-2) co-place GPUs, NICs, CPUs, and memory on the same NUMA boundary at scheduling time. DRA does the allocation and topology decisions — KubeVirt just reads what it's given in the KEP-5304 metadata and lays out the guest topology to match.

## Steps Required

### 1. Standardized topology attributes and cross-driver NUMA alignment

Each DRA driver (GPU, NIC, CPU, memory) must read and publish the physical location of every device — NUMA node, PCIe root, PCI bus address — as ResourceSlice attributes. Today each driver publishes NUMA under a different vendor-specific name. A standard `resource.kubernetes.io/numaNode` is needed so all drivers speak the same language. With that standard attribute, one `matchAttribute` constraint in the scheduler co-locates GPUs + NICs + CPUs + memory from 4 independent drivers — no middleware required.

**To complete:**
- **Kubernetes upstream** — agree to standardize `resource.kubernetes.io/numaNode` and `cpuSocketID` in the `deviceattribute` library ([proposal](docs/upstream-proposals/standardize-numanode-and-socket.md))
- **NVIDIA GPU DRA driver** — expose NUMA for standard GPU devices (currently only published for VFIO type)
- **AMD GPU DRA driver** — publish the standard `resource.kubernetes.io/pciBusID` (currently uses vendor-specific `pciAddr`)
- **All 4 drivers** — publish standardized attributes alongside vendor-specific ones
- Without the standard attribute, cross-driver alignment requires middleware (step 3) or per-driver CEL selector workarounds

### 2. Topology distance hierarchy

Not all co-location is equal. Devices can share a PCIe switch (tightest), a NUMA node (local), or a CPU socket (loosest). The scheduler needs a fallback chain — prefer the tightest coupling available, relax when hardware doesn't support it. This requires an `enforcement: Preferred` capability in the scheduler.

**To complete:**
- **Kubernetes upstream** — add `enforcement: Preferred` field to `DeviceConstraint` API; covered by the same [proposal](docs/upstream-proposals/standardize-numanode-and-socket.md)
- **kube-apiserver** — accept, validate, and store the new field
- **kube-scheduler** — skip preferred constraints when unsatisfiable
- **kube-controller-manager, kubelet, kubectl** — preserve the field through the claim lifecycle

### 3. Machine partitioning *(nice-to-have)*

Users should be able to request "a slice of the machine" (e.g., one-eighth) rather than manually specifying 4 drivers, their counts, and constraints. A topology coordinator controller creates partition DeviceClasses and a webhook expands simple claims into multi-driver NUMA-aligned requests. This is most useful for symmetric configurations where the machine can be evenly divided into identical partitions. This is a usability improvement — steps 1-2 provide the core alignment capability without it.

**To complete:**
- **Topology coordinator** — merge 6 bug-fix patches (label truncation, attribute namespace, CEL selector forwarding, pcieRoot filtering, distance-based fallback)
- **Topology coordinator** — address webhook unavailability during controller restarts

### 4. VFIO device passthrough via DRA

VMs receive devices via VFIO passthrough, not sharing. DRA drivers must manage the full lifecycle: unbind from the native kernel driver, bind to `vfio-pci`, expose `/dev/vfio/*` device nodes, and handle IOMMU groups.

**To complete:**
- **AMD GPU DRA driver** — add VFIO bind/unbind lifecycle and CDI device generation; fix GPU discovery after VFIO unbind
- **SR-IOV NIC DRA driver** — add formal VFIO mode (skip CNI/RDMA for VFIO-bound VFs)
- **NVIDIA GPU DRA driver** — has `type: vfio` support behind the `PassthroughSupport` feature gate

### 5. Device metadata (KEP-5304)

The KubeVirt virt-launcher needs to know each device's PCI address and NUMA node to configure the VM. KEP-5304 (native in K8s 1.36) is a Kubernetes API that lets DRA drivers attach metadata (key-value attributes) to allocated devices. When a device is prepared, the driver publishes attributes like PCI address and NUMA node. The kubelet writes these as JSON files and mounts them into the pod at a well-known path. Virt-launcher reads the PCI address to create VFIO passthrough entries in the VM's domain XML, and reads the NUMA node to place each device on the correct guest NUMA node.

**To complete:**
- **Kubernetes kubelet** — fix bug where multi-driver claims only inject metadata for one driver
- **AMD GPU DRA driver** — opt in to KEP-5304 and publish standard `resource.kubernetes.io/pciBusID`
- **SR-IOV NIC DRA driver** — opt in to KEP-5304 and publish device metadata
- **NVIDIA GPU DRA driver** — KEP-5304 opt-in in progress (issue #916, targeting v26.4.0)

### 6. Guest NUMA topology

The virt-launcher must read the device metadata (step 5) and create matching guest NUMA topology. This means building `pxb-pcie` expander buses on the correct guest NUMA nodes (VEP 115) and mapping host NUMA IDs to guest cell IDs.

**To complete:**
- **KubeVirt virt-launcher** — read DRA device NUMA from KEP-5304 metadata in VEP 115 (currently only reads sysfs for device-plugin devices)
- **KubeVirt virt-controller** — add VFIO capabilities (SYS_RESOURCE, IPC_LOCK, unlimited memlock) for DRA host device pods
- **KubeVirt virt-controller** — skip `permittedHostDevices` validation for DRA-allocated devices (partially addressed upstream with `HostDevicesWithDRA` feature gate)
- **KubeVirt** — auto-enable ACPI when guest NUMA topology is used

## Current State

All 6 steps have been proven end-to-end on real hardware (Dell XE9680 with AMD MI300X and Dell R760xa with NVIDIA A40) with local patches as a POC.

## Testing

Tested on Dell XE9680 (2-socket Intel Xeon 6448Y, 8x AMD MI300X GPUs, 2x Mellanox ConnectX-6 Dx NICs, 128 CPUs, ~2 TiB RAM) with K8s 1.36.0-rc.0, Fedora 43.

| Test | Result |
|------|--------|
| 4-driver eighth pods (SNC off) | Running — 2 pods, each with CPU + memory + 2 GPUs + 2 NICs, NUMA-aligned |
| 4-driver quarter pods (SNC off) | Running — 2 pods, each with CPU + 258GB + 2 GPUs + 2 NICs |
| Tight vs loose coupling (SNC on) | Both running — tight (pcieRoot matched) + loose (NUMA-only) |
| KubeVirt single-NUMA VM | Running — GPU + NIC on guest NUMA 0 via pxb-pcie |
| KubeVirt dual-NUMA VM (SNC off) | Running — 2 pxb-pcie expanders, correct guest NUMA topology |
| KubeVirt dual-NUMA VM (SNC on) | Running — host NUMA 0→guest 0, host NUMA 2→guest 1 |
| SNC-2 on vs off comparison | Coordinator adapts automatically — 9 vs 5 DeviceClasses |

See [Test Results Summary](testing/results/results-summary.md) for full details, hardware captures, and SNC comparison.

## Documentation

| Document | Description |
|----------|-------------|
| [Full Technical Document](docs/path-to-topology-aware-vms.md) | Detailed 6-step breakdown with YAML examples, test evidence, and code references |
| [Project Narrative](docs/project-narrative.md) | 3 stories: pod placement → KubeVirt VMs → upstream proposals |
| [Gap Analysis](docs/gap-analysis.md) | Detailed technical analysis of 8 gaps, driver comparisons, attribute tables |
| [Topology Attribute Debate](docs/topology-attribute-debate.md) | Upstream numaNode vs pcieRoot vs cpuSocketNumber debate, SNC/NPS problems |
| [Architecture](docs/architecture.md) | Component diagrams, hardware layout, allocation flows |
| [Topology Use Cases](docs/topology-use-cases.md) | AI workloads mapped to each distance level: pcieRoot, numaNode, socket, node |
| [Topology Coordinator Design](docs/topology-coordinator.md) | Partition abstraction, webhook expansion, distance-based fallback |
| [Upstream Roadmap](docs/upstream-roadmap.md) | Patches across 7 repos with status and upstream actions |
| [Patched Repos](docs/patched-repos.md) | All forks, branches, and descriptions |
| [Test Results Summary](testing/results/results-summary.md) | Comparison matrix across K8s versions, SNC on/off, bugs found |

### Upstream Proposals

| Proposal | Description |
|----------|-------------|
| [Standardize numaNode and socket](docs/upstream-proposals/standardize-numanode-and-socket.md) | Engineering proposal: sysfs sources, helper functions, distance hierarchy, SNC/NPS |
| [Distance Hierarchy Proposal](docs/upstream-proposals/proposal-topology-distance-hierarchy.md) | Condensed proposal for upstream working group |
| [KEP-5304 Auto-Populate Metadata](docs/upstream-proposals/kep5304-auto-populate-metadata.md) | Kubelet auto-copies ResourceSlice attributes into KEP-5304 metadata |
| [KubeVirt Multi-Device DRA Requests](docs/upstream-proposals/kubevirt-multi-device-dra-requests.md) | KubeVirt hostDevices with count>1 DRA requests |

## References

- [KEP-4381: DRA Structured Parameters](https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/4381-dra-structured-parameters/README.md)
- [KEP-5304: Native Device Metadata API](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5304-dra-with-dra-driver-device-metadata)
- [KEP-5491: List Types for Attributes](https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/5491-dra-list-types-for-attributes) (alpha in v1.36, feature gate `DRAListTypeAttributes`)
- [KEP-5491 implementation PR](https://github.com/kubernetes/kubernetes/pull/137190) (merged 2026-03-21)
- [KEP-5517: DRA for Native Resources](https://github.com/kubernetes/enhancements/pull/5755)
- [VEP 115: PCI NUMA-Aware Topology](https://github.com/kubevirt/community/pull/303)
- [DRA driver interoperability tracking](https://github.com/kubernetes-sigs/dra-driver-cpu/issues/56)
- [`cpuSocketNumber` standardization discussion](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)
- [WIP: `GetPCIeRootAttributeMapFromCPUId` helper](https://github.com/kubernetes/kubernetes/pull/138297)
- [NVIDIA DRA Driver](https://github.com/NVIDIA/k8s-dra-driver-gpu)
- [AMD GPU DRA Driver](https://github.com/ROCm/k8s-gpu-dra-driver)
- [CPU DRA Driver](https://github.com/kubernetes-sigs/dra-driver-cpu) (kubernetes-sigs)
- [Memory DRA Driver](https://github.com/kad/dra-driver-memory) (personal repo, early development)
- [Node Partition Topology Coordinator](https://github.com/fabiendupont/k8s-dra-topology-coordinator) (POC by Fabien Dupont)
- [The Kubernetes Network Driver Model](https://arxiv.org/abs/2506.23628) — GPU/NIC DRA alignment benchmarks (Ojea 2025)
- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)

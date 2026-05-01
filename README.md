# Topology-Aware Device Co-Placement in KubeVirt VMs

**Date:** 2026-04-28

## Goal

Use DRA to co-place devices (GPUs, NICs, CPUs, memory) in KubeVirt VMs with full topology — so that devices on the same NUMA node or PCIe root on the host are reflected with matching topology inside the guest VM.

## Why

Without topology awareness, device assignment is random. A GPU on one side of the machine and a NIC on the other means every data transfer crosses internal bus boundaries. Benchmarks show aligned placement delivers **58% higher throughput** with near-zero variance versus unaligned ([Ojea 2025](https://arxiv.org/abs/2506.23628)). For VMs, the guest OS must also see the correct topology for AI frameworks to take advantage of it.

## How It Works Today

KubeVirt passthrough devices are allocated via the device plugin API. The kubelet's topology manager coordinates CPU, memory, and device plugin allocations onto the same NUMA node. VEP 115 (KubeVirt's PCI NUMA-Aware Topology feature) reads each device's NUMA from host sysfs and builds matching guest topology by placing devices on `pxb-pcie` expander buses assigned to the correct guest NUMA node. This works end-to-end for device-plugin devices.

## What Changes with DRA

DRA allocation happens in the scheduler, not the kubelet — the topology manager has no awareness of DRA devices. For DRA to replace the topology manager's coordination role, all four resource types (GPUs, NICs, CPUs, and memory) must be managed by DRA so they can be co-placed through a single scheduler constraint. Additionally, DRA devices bypass the device plugin API, so KubeVirt needs KEP-5304 metadata to discover their PCI addresses and NUMA placement.

DRA replaces the topology manager's coordination role for these resources. Cross-driver constraints in the scheduler (steps 1-2) co-place GPUs, NICs, CPUs, and memory on the same NUMA boundary at scheduling time. DRA does the allocation and topology decisions — KubeVirt just reads what it's given in the KEP-5304 metadata and lays out the guest topology to match.

## Steps Required

### 1. Standardized topology attributes and cross-driver NUMA alignment

Each DRA driver (GPU, NIC, CPU, memory) must read and publish the physical location of every device — NUMA node, PCIe root, PCI bus address — as ResourceSlice attributes. Today each driver publishes NUMA under a different vendor-specific name. A standard `resource.kubernetes.io/numaNode` is needed so all drivers speak the same language. With that standard attribute, one `matchAttribute` constraint in the scheduler co-locates GPUs + NICs + CPUs + memory from 4 independent drivers — no middleware required.

**Issues:** [U-2](docs/issues.md#u-2-standardized-resourcekubernetesionumanode-not-agreed) (feature), [D-2](docs/issues.md#d-2-nvidia-gpu-dra-driver-numanode-not-published-for-standard-gpu-devices) (feature), [D-5](docs/issues.md#d-5-dranet-standardized-topology-attributes-not-upstream) (feature), [D-8](docs/issues.md#d-8-amd-gpu-dra-driver-numanode-attribute-not-standardized) (feature)

### 2. Topology distance hierarchy *(optional)*

Not all co-location is equal. Devices can share a PCIe switch (tightest) or a NUMA node (local). The scheduler could prefer `pcieRoot` (same switch) and fall back to `numaNode` (same memory controller). This requires an `enforcement: Preferred` capability in the scheduler. Step 1 alone handles the critical co-placement boundary — this step adds an optimization for systems with PCIe switches. NCCL/RCCL already handle PCIe-level proxy selection at the application level.

**Issues:** [U-1](docs/issues.md#u-1-enforcement-preferred-not-in-upstream-api) (feature), [U-3](docs/issues.md#u-3-deviceattribute-library-getpcierootattributemapfromcpuid-helper) (feature)

### 3. DRA-aware CPU pinning

DRA scheduling (steps 1-2) co-places devices at the scheduler level, but CPU pinning is handled separately. Without coordination, CPUs may be pinned to a different NUMA node than the DRA devices. This applies to both regular pods and KubeVirt VMs — for VMs it's especially critical because virt-launcher reads `cpuset.cpus` at startup to build guest NUMA topology, so wrong CPU pinning cascades into wrong guest device placement.

There are [two mutually exclusive options](docs/issues.md#cpu-pinning-with-dra-devices--two-options): **(A)** the DRA CPU driver allocates CPUs as DRA devices alongside GPUs/NICs in the same claim, or **(B)** the kubelet gets DRA topology hints and pins CPUs via its own CPU manager. Both are proven on the R760xa.

**Issues:** [K-1](docs/issues.md#k-1-dra-topology-hints--kubelet-doesnt-provide-numa-hints-for-dra-devices) (feature), [K-2](docs/issues.md#k-2-cpu-manager-reconciler-never-corrects-cgroup-cpuset-mismatches) (bug), [K-3](docs/issues.md#k-3-cpu-manager-cpuset-not-applied-before-container-starts) (bug)

### 4. Machine partitioning *(nice-to-have)*

Users should be able to request "a slice of the machine" (e.g., one-eighth) rather than manually specifying 4 drivers, their counts, and constraints. A topology coordinator controller creates partition DeviceClasses and a webhook expands simple claims into multi-driver NUMA-aligned requests. This is most useful for symmetric configurations where the machine can be evenly divided into identical partitions. This is a usability improvement — steps 1-2 provide the core alignment capability without it.

**Issues:** [TC-1](docs/issues.md#tc-1-6-bug-fix-patches-not-merged-upstream) (bug), [TC-2](docs/issues.md#tc-2-webhook-unavailable-during-controller-restarts) (bug)

### 5. VFIO device passthrough via DRA *(KubeVirt)*

VMs receive devices via VFIO passthrough, not sharing. DRA drivers must manage the full lifecycle: unbind from the native kernel driver, bind to `vfio-pci`, expose `/dev/vfio/*` device nodes, and handle IOMMU groups.

**Issues:** [D-4](docs/issues.md#d-4-dranet-vfio-support-not-upstream) (feature), [D-6](docs/issues.md#d-6-amd-gpu-dra-driver-vfio-bindunbind-lifecycle-missing) (feature)

### 6. Device metadata (KEP-5304) *(KubeVirt)*

The KubeVirt virt-launcher needs to know each device's PCI address and NUMA node to configure the VM. KEP-5304 (native in K8s 1.36) is a downward API for DRA devices — it lets DRA drivers attach metadata (key-value attributes) to allocated devices and projects them into the pod as files. When a device is prepared, the driver publishes attributes like PCI address and NUMA node. The kubelet writes these as JSON files and mounts them into the pod at a well-known path. Virt-launcher reads the PCI address to create VFIO passthrough entries in the VM's domain XML, and reads the NUMA node to place each device on the correct guest NUMA node.

**Issues:** [K-4](docs/issues.md#k-4-multi-driver-claims-may-only-inject-kep-5304-metadata-for-one-driver) (bug), [D-1](docs/issues.md#d-1-sr-iov-dra-driver-has-no-kep-5304-pcibusid-metadata) (feature), [D-3](docs/issues.md#d-3-nvidia-gpu-dra-driver-kep-5304-opt-in-not-yet-available) (feature), [D-7](docs/issues.md#d-7-amd-gpu-dra-driver-kep-5304-metadata-opt-in) (feature)

### 7. Guest NUMA topology *(KubeVirt)*

The virt-launcher must read the device metadata (step 5) and create matching guest NUMA topology. This means building `pxb-pcie` expander buses on the correct guest NUMA nodes (VEP 115) and mapping host NUMA IDs to guest cell IDs.

**Issues:** [KV-5](docs/issues.md#kv-5-vep-115-reads-device-numa-from-sysfs-only-not-from-dra-kep-5304-metadata) (feature), [KV-6](docs/issues.md#kv-6-acpi-not-auto-enabled-when-guest-numa-topology-is-used) (bug), [KV-7](docs/issues.md#kv-7-virt-controller-missing-vfio-capabilities-for-dra-host-device-pods) (feature)

## Current State

All 7 steps have been proven end-to-end on real hardware with local patches as a POC:

- **Dell R760xa** (NVIDIA A40) — active test system. Option A CPU pinning (`cpuManagerPolicy: none`, DRA CPU driver). KV-8 fix deployed (patched virt-controller skips cpumanager label check). Multi-NUMA VM test in progress: GPU on NUMA 0 + NIC on NUMA 1 passes scheduling and DRA preparation, blocked on VFIO capabilities for NIC hostDevice.
- **Dell XE9680** (AMD MI300X) — original test system. 8-GPU topology coordinator tests, SNC on/off comparison, multi-NUMA VMs.
- **Dell XE8640** (NVIDIA H100 SXM5) — rebuilt with Fedora 44. All 5 DRA drivers deployed. Option A CPU pinning (`cpuManagerPolicy: none`). Multi-NUMA VM running with 3x H100 VFIO passthrough (2 on NUMA 0, 1 on NUMA 1), correct guest NUMA topology via `pxb-pcie` expanders from KEP-5304 metadata. GPUs pre-bound to vfio-pci at boot (`vfio-pci.ids`), one GPU kept on nvidia for NVML. D-11 through D-15 and KV-9/KV-10 fixed.

All open and closed issues are tracked in [issues.md](docs/issues.md). See [Setup Guide](docs/dra-topology-aware-vm-setup.md) for build and deployment.

## Testing

### Dell R760xa (NVIDIA, active)

2-socket Intel Xeon Gold 6548Y+, 2x NVIDIA A40, ConnectX-7 NICs with dranet, 128 threads. K8s custom v1.37.0-alpha (enforcement:preferred + DRA topology hints). Fedora 43.

| Test | Result |
|------|--------|
| Per-CPU individual mode (`--cpu-device-mode=individual`) | Working — 128 CPU devices, `count: N` in claims, multi-claim per NUMA |
| 3 claims × 8 CPUs NUMA-aligned (GPU+NIC+CPU) | Working — all CPUs on correct NUMA via `matchAttribute` |
| Option A CPU pinning (`cpuManagerPolicy: none`) | Working — DRA CPU driver pins CPUs via NRI |
| KV-8 fix (skip cpumanager label with DRA claims) | Working — VM schedules with `kubevirt.io/cpumanager=false` when DRA resource claims present |
| KubeVirt VM with `guestMappingPassthrough` | Running — A40 GPU VFIO, dedicated CPUs on NUMA 0, guest sees 1 socket/1 NUMA |
| dranet VFIO safety filter (D-16) | Working — `vfioUnsafe` attribute, shared IOMMU group + default gateway detection |
| dranet KEP-5304 metadata | Working — publishes `pciBusID` in PrepareResult for KubeVirt passthrough |

### Dell XE9680 (AMD)

2-socket Intel Xeon 6448Y, 8x AMD MI300X GPUs, 2x Mellanox ConnectX-6 Dx NICs, 128 CPUs, ~2 TiB RAM. K8s 1.36.0-rc.0, Fedora 43.

| Test | Result |
|------|--------|
| 4-driver eighth pods (SNC off) | Running — 2 pods, each with CPU + memory + 2 GPUs + 2 NICs, NUMA-aligned |
| 4-driver quarter pods (SNC off) | Running — 2 pods, each with CPU + 258GB + 2 GPUs + 2 NICs |
| Tight vs loose coupling (SNC on) | Both running — tight (pcieRoot matched) + loose (NUMA-only) |
| KubeVirt single-NUMA VM | Running — GPU + NIC on guest NUMA 0 via pxb-pcie |
| KubeVirt dual-NUMA VM (SNC off) | Running — 2 pxb-pcie expanders, correct guest NUMA topology |
| KubeVirt dual-NUMA VM (SNC on) | Running — host NUMA 0→guest 0, host NUMA 2→guest 1 |
| SNC-2 on vs off comparison | Coordinator adapts automatically — 9 vs 5 DeviceClasses |

### Dell XE8640 (NVIDIA H100 SXM5)

2-socket Intel, 4x NVIDIA H100 SXM5 80GB (NVLink), CX6Dx + E810 NICs, 4x NVMe, 128 threads, 1 TiB RAM. K8s custom v1.36.0 (DRA topology hints). Fedora 44, nvidia driver 595.58. Option A: `cpuManagerPolicy: none`, DRA CPU driver NRI pinning.

| Test | Result |
|------|--------|
| Per-CPU individual mode | Working — 128 CPU devices, `count: N` in claims, multi-claim per NUMA |
| 4-claim test (pcieRoot + numaNode + 2 GPU-only) | Working — all 4 H100s allocated with 4 CPUs each, all NUMA-aligned |
| 3-GPU multi-NUMA VM (2 NUMA 0 + 1 NUMA 1) | Running — 3x H100 VFIO + NIC + 8 CPUs (4/NUMA), guest NUMA 0+1, `pxb-pcie` expanders |
| Guest NUMA device affinity | Working — GPUs on NUMA 0 report `numa_node=0`, GPU on NUMA 1 reports `numa_node=1` inside guest |
| Option A CPU pinning | Working — DRA CPU driver NRI pins compute container cpuset |
| KEP-5304 metadata → guest NUMA | Working — `DiscoverNUMANodesFromAllMetadata` reads GPU NUMA from KEP-5304, builds guest cells |
| Boot-time GPU binding (`vfio-pci.ids`) | Working — 3 GPUs on vfio-pci at boot, GPU operator binds 1 to nvidia for NVML |
| VFIO discovery filter (D-13) | Working — only vfio-pci-bound GPUs in ResourceSlice |
| dranet VFIO safety filter (D-16) | Working — shared IOMMU group detection, `vfioUnsafe` attribute |
| NVMe boot disk exclusion (D-17) | Working — `/proc/1/mounts` check skips boot NVMe |

See [Test Results Summary](testing/results/results-summary.md) for full details, hardware captures, and SNC comparison.

## Documentation

| Document | Description |
|----------|-------------|
| [Setup Guide](docs/dra-topology-aware-vm-setup.md) | End-to-end setup: kubelet build, DRA drivers, KubeVirt config, VM creation |
| [Full Technical Document](docs/path-to-topology-aware-vms.md) | Detailed 6-step breakdown with YAML examples, test evidence, and code references |
| [Topology Attribute Debate](docs/topology-attribute-debate.md) | Upstream numaNode vs pcieRoot debate, SNC/NPS analysis |
| [Topology Use Cases](docs/topology-use-cases.md) | AI workloads mapped to each distance level: pcieRoot, numaNode, socket, node |
| [Topology Coordinator Design](docs/topology-coordinator.md) | Partition abstraction, webhook expansion, distance-based fallback |
| [Patched Repos](docs/patched-repos.md) | All forks, branches, and descriptions |
| [Test Results Summary](testing/results/results-summary.md) | Comparison matrix across K8s versions, SNC on/off, bugs found |

### Upstream Proposals

| Proposal | Description |
|----------|-------------|
| [Standardize numaNode](docs/upstream-proposals/standardize-numanode.md) | Engineering proposal: sysfs sources, helper functions, enforcement:preferred |
| [Distance Hierarchy Proposal](docs/upstream-proposals/proposal-topology-distance-hierarchy.md) | Condensed proposal for upstream working group |
| [KEP-5304 Auto-Populate Metadata](docs/upstream-proposals/kep5304-auto-populate-metadata.md) | Kubelet auto-copies ResourceSlice attributes into KEP-5304 metadata |
| [KubeVirt Multi-Device DRA Requests](docs/upstream-proposals/kubevirt-multi-device-dra-requests.md) | KubeVirt hostDevices with count>1 DRA requests |

## References

- [KEP-4381: DRA Structured Parameters](https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/4381-dra-structured-parameters/README.md)
- [KEP-5304: Native Device Metadata API](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5304-dra-with-dra-driver-device-metadata)
- [KEP-5491: List Types for Attributes](https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/5491-dra-list-types-for-attributes) (alpha in v1.36, feature gate `DRAListTypeAttributes`)
- [KEP-5491 implementation PR](https://github.com/kubernetes/kubernetes/pull/137190) (merged 2026-03-21)
- [KEP-5517: DRA for Native Resources](https://github.com/kubernetes/enhancements/pull/5755)
- [VEP 10: GPUsWithDRA](https://github.com/kubevirt/enhancements/pull/155) — KubeVirt GPU passthrough via DRA using KEP-5304 downward API (beta via [PR #292](https://github.com/kubevirt/enhancements/pull/292)). This project adds NUMA-aware guest topology on top of VEP-10's device plumbing.
- [VEP 183: NetworkDevicesWithDRA](https://github.com/kubevirt/enhancements/pull/185) — KubeVirt NIC passthrough via DRA. This project adds cross-driver NUMA coordination between VEP-10 GPUs and VEP-183 NICs.
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

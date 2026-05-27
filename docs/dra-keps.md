# DRA & KubeVirt Enhancement Tracking

Kubernetes KEPs and KubeVirt VEPs relevant to topology-aware co-placement.

## Directly Relevant

These KEPs define whether topology-aware co-placement works in DRA.

| KEP | Name | Stage | Relevance |
|-----|------|-------|-----------|
| [4815](https://github.com/kubernetes/enhancements/issues/4815) | DRA: Partitionable Devices | Beta v1.36 (alpha v1.33) | Allows drivers to advertise overlapping device partitions so the scheduler prevents conflicting allocations. Covers MIG GPU partitioning, multi-host TPU topology slicing, and SR-IOV. The scheduler picks non-conflicting partitions from a "bag of resources" model — partitions are created *after* allocation, not before. Directly enables dynamic GPU partitioning for co-placed workloads. |
| [5304](https://github.com/kubernetes/enhancements/issues/5304) | DRA: Attributes Downward API | Alpha v1.36 | Exposes device attributes (PCIe bus address, NUMA node, UUIDs) to workloads via CDI file mounts at `/var/run/dra-device-attributes/`. Drivers populate a `Metadata` field in `PrepareResult`; the DRA framework writes per-request JSON files into containers. Supports immediate (GPU) and deferred (network/CNI) delivery modes. KubeVirt's virt-launcher needs this to build guest NUMA topology from host device metadata (VEP-115). |
| [6072](https://github.com/kubernetes/enhancements/issues/6072) | DRA: Standard numaNode Device Attribute | Provisional, alpha target v1.37 | Standardizes `resource.kubernetes.io/numaNode` as a well-known device attribute alongside `pcieRoot` and `pciBusID`. Today 6 DRA drivers publish NUMA info under 5 different names — `matchAttribute` requires a common name. Provides `GetNUMANodeByPCIBusID()` and `GetNUMANodeForCPU()` helpers. Enables cross-driver NUMA co-placement via a single constraint: `matchAttribute: resource.kubernetes.io/numaNode`. Measures memory topology (which memory controller), orthogonal to `pcieRoot` (which PCIe switch tree). |
| [5963](https://github.com/kubernetes/enhancements/issues/5963) | DRA: Device Compatibility Groups | Alpha target v1.37 | Extends DRA API to let devices define compatibility constraints, preventing allocation of mutually exclusive hardware partitioning modes. Ensures the scheduler doesn't allocate incompatible device configurations (e.g., conflicting MIG profiles or NPS modes). |
| [5981](https://github.com/kubernetes/enhancements/issues/5981) | DRA: Sharing Affinity for Consumable Capacity | No milestone yet | Adds a `sharingAffinity` field to device specs so drivers can declare which claim parameters must match for device sharing. Without this, drivers must use placeholder devices and dynamically expand/contract capacity — error-prone and racy. Use cases: share NIC only if pods request same subnet, share GPU only within same tenant, share FPGA only for same bitstream. |

## Important

These shape what's expressible in topology-aware co-placement.

| KEP | Name | Stage | Relevance |
|-----|------|-------|-----------|
| [5075](https://github.com/kubernetes/enhancements/issues/5075) | DRA: Consumable Capacity | Beta v1.36 (alpha v1.34, GA target v1.37) | Enables independent ResourceClaims to allocate *shares* of the same device, drawn from its overall capacity. Introduces `allowMultipleAllocations` on devices, capacity-aware scheduling with per-claim minimums (`requestPolicy`), and `distinctAttribute` constraints to prevent same-device double-allocation within a claim. Prerequisite for shared GPU memory accounting across co-placed workloads. |
| [5941](https://github.com/kubernetes/enhancements/issues/5941) | DRA: Shared Consumable Capacity | Alpha target v1.37 | Allows drivers to define parent-scoped shared capacities consumed per allocation by child devices. Scheduler accounting prevents aggregate over-allocation. Enables modeling like "4 GPUs share 512GB of HBM on a single GPU module" where per-GPU allocations deduct from the shared pool. |
| [5055](https://github.com/kubernetes/enhancements/issues/5055) | DRA: Device Taints and Tolerations | Beta v1.36 (alpha v1.33, GA target v1.37) | Drivers can taint devices (degraded, overheating, maintenance) to prevent scheduling. Cluster admins can create `DeviceTaintRule` resources matching device selectors. Users tolerate specific taints in ResourceClaims. Supports safe pod eviction — preview what would be evicted before activating. Useful for marking degraded NUMA domains or GPUs with ECC errors without removing them from ResourceSlice. |
| [5007](https://github.com/kubernetes/enhancements/issues/5007) | DRA: Device Binding Conditions | Beta v1.36 (alpha v1.34, GA target v1.37) | Defers pod binding until external resources are confirmed ready via `BindingConditions`. Originally motivated by fabric-attached GPUs (PCIe/CXL switches) where device attachment is asynchronous. The scheduler waits for conditions to be `True` before binding; `BindingFailureConditions` trigger rescheduling. Relevant for composable disaggregated infrastructure where GPUs are dynamically attached. |
| [6080](https://github.com/kubernetes/enhancements/issues/6080) | DRA: Derived Attributes | Alpha target v1.37 | Extends `DeviceRequest` with `derivedAttributes` — scoped CEL expressions evaluated at allocation time. Enables inline device co-allocation across different vendor attribute schemas without requiring drivers to agree on names. Could express computed topology relationships like "same IOD quadrant" or "within N hops" without driver changes. |
| [5690](https://github.com/kubernetes/enhancements/issues/5690) | DRA: Preemption | No milestone yet, priority TBD | Currently the DRA scheduler plugin does not support preemption at all — pods using DRA devices cannot be preempted. This KEP would add simulation of ResourceClaim deallocation during preemption evaluation. Without it, lower-priority GPU pods block higher-priority ones indefinitely. |
| [5491](https://github.com/kubernetes/enhancements/issues/5491) | DRA: List Types for Attributes | Alpha v1.36 | Adds list-typed attribute values (`[]int`, `[]string`, etc.) to `DeviceAttribute`. Redefines `matchAttribute` as non-empty set intersection (not equality) and `distinctAttribute` as pairwise disjoint. Scalars treated as single-element lists for backward compatibility. Directly needed for CPUs with adjacency to multiple PCIe roots, NICs reachable from multiple NUMA nodes, or any device with multi-valued topology relationships. Critical for R7725 NPS4 topology where GPUs connect to multiple IOD quadrants. |

## KubeVirt Enhancements

VEPs that intersect with DRA topology-aware VM placement.

| VEP | Name | Status | Relevance |
|-----|------|--------|-----------|
| [VEP-115](https://github.com/kubevirt/enhancements/issues/115) | PCIe NUMA Topology Awareness | Alpha target: v1.8, Beta target: v1.9 | NUMA-aware PCIe device assignment for VMs. virt-launcher reads KEP-5304 device metadata to build guest NUMA topology. Direct enabler for topology-aware VM placement. |
| [VEP-10](https://github.com/kubevirt/enhancements/issues/10) | Support GPU DRA Devices in KubeVirt | Alpha: v1.6.0, Alpha2: v1.8.0 | GPU device support via DRA — prerequisite for GPU co-placement in VMs. Multi-phase rollout with dependency bumps, API changes, and e2e testing. |
| [VEP-152](https://github.com/kubevirt/enhancements/issues/152) | CPU DRA Driver Support | Removed from v1.9 milestone | CPU allocation via DRA. Deferred but needed for full topology-aware CPU+GPU co-placement. Without this, CPU NUMA affinity in VMs must use other mechanisms. |
| [VEP-183](https://github.com/kubevirt/enhancements/issues/183) | Network Devices with DRA | Tracking for v1.9 | Network device allocation via DRA. Completes the NIC leg of GPU+NIC NUMA co-placement in VMs. |

# DRA & KubeVirt Enhancement Tracking

Kubernetes KEPs and KubeVirt VEPs relevant to topology-aware co-placement.

## Directly Relevant

These KEPs define whether topology-aware co-placement works in DRA.

| KEP | Name | Relevance |
|-----|------|-----------|
| [4815](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/4815-dra-partitionable-devices) | DRA: Partitionable Devices | GPU partitioning (MIG, SR-IOV). Active KubeVirt bugs against this (partition GPU count). |
| [5304](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5304-dra-attributes-downward-api) | DRA: Attributes Downward API | VMs need to discover device topology at runtime. Active bugs (metadata parsing). |
| [6072](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/6072-dra-standard-numanode-device-attribute) | DRA: Standard numaNode Device Attribute | Standardizes the NUMA node attribute — foundational for topology-aware placement. |
| [5963](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5963-dra-device-compatibility-groups) | DRA: Device Compatibility Groups | Express "these devices must be topologically compatible" for co-placement. |
| [5981](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5981-dra-sharing-affinity-for-consumable-capacity) | DRA: Sharing Affinity for Consumable Capacity | NUMA-aware affinity for shared resources in multi-NUMA GPU scenarios. |

## Important

These shape what's expressible in topology-aware co-placement.

| KEP | Name | Relevance |
|-----|------|-----------|
| [5075](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5075-dra-consumable-capacity) | DRA: Consumable Capacity | GPU memory tracking and capacity modeling for partitioned devices. |
| [5941](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5941-dra-shared-consumable-capacity) | DRA: Shared Consumable Capacity | Shared GPU memory across partitions. |
| [5055](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5055-dra-device-taints-and-tolerations) | DRA: Device Taints and Tolerations | Marking devices/NUMA domains as degraded or reserved. |
| [5007](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5007-dra-device-binding-conditions) | DRA: Device Binding Conditions | Understanding when device bindings succeed/fail — debugging co-placement. |
| [6080](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/6080-dra-derived-attributes) | DRA: Derived Attributes | Computed topology attributes (e.g., "same IOD quadrant"). |
| [5690](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5690-dra-preemption) | DRA: Preemption | GPU workload preemption for multi-tenant co-placement. |
| [5491](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5491-dra-list-types-for-attributes) | DRA: List Types for Attributes | Express multi-valued topology facts per device (e.g., GPU reachable from multiple NUMA nodes, NIC with multiple PCIe paths). Critical for complex topologies like R7725 NPS4. |

## KubeVirt Enhancements

VEPs that intersect with DRA topology-aware VM placement.

| VEP | Name | Status | Relevance |
|-----|------|--------|-----------|
| [VEP-115](https://github.com/kubevirt/enhancements/issues/115) | PCIe NUMA Topology Awareness | Alpha target: v1.8, Beta target: v1.9 | NUMA-aware PCIe device assignment for VMs. Direct enabler for topology-aware placement. |
| [VEP-10](https://github.com/kubevirt/enhancements/issues/10) | Support GPU DRA Devices in KubeVirt | Alpha: v1.6.0, Alpha2: v1.8.0 | GPU device support via DRA — prerequisite for GPU co-placement in VMs. |
| [VEP-152](https://github.com/kubevirt/enhancements/issues/152) | CPU DRA Driver Support | Removed from v1.9 milestone | CPU allocation via DRA. Deferred but needed for full topology-aware CPU+GPU co-placement. |
| [VEP-183](https://github.com/kubevirt/enhancements/issues/183) | Network Devices with DRA | Tracking for v1.9 | Network device allocation via DRA. Completes the NIC leg of GPU+NIC co-placement. |

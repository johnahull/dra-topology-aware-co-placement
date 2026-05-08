# DRA KEP Ecosystem: Relationship to Topology-Aware Co-Placement

## Overview

The DRA KEP ecosystem is building toward a world where the Kubernetes scheduler
natively understands hardware topology. This project is 12-18 months ahead of
upstream -- these KEPs will formalize pieces already proven on real hardware
(Dell XE8640, R760xa) with multi-NUMA GPU, NIC, CPU, memory, and NVMe
co-placement.

This document maps 12+ active DRA-related Kubernetes Enhancement Proposals to
the topology-aware co-placement project, identifies what each KEP replaces, and
highlights the gaps that still require the topology coordinator.

## Three Waves of Capability

### Wave 1 -- Device Identity (K8s 1.34-1.36, mostly done)

Foundation. DRA drivers publish devices with attributes, the scheduler matches
them, and metadata flows to pods.

- **KEP-4381**: Structured parameters (done)
- **KEP-5304**: Attributes downward API (alpha)
- **KEP-5491**: List-typed attributes (alpha in 1.36)
- **KEP-4817**: Claim status (beta)
- **KEP-5007**: Binding conditions (beta)

### Wave 2 -- Dynamic Topology (K8s 1.36-1.38, in progress)

Static device inventories become dynamic, topology-aware hierarchies.

- **KEP-5075**: Consumable capacity (beta in 1.36) -- lets a device be shared
  across claims with tracked capacity (e.g., NIC bandwidth). Uses
  `allowMultipleAllocations` and capacity fields.
- **KEP-4815**: Partitionable devices (alpha) -- overlapping partition options
  for a single device with shared counter sets (e.g., MIG profiles, AMD CPX
  mode). NOT for cross-driver bundling.
- **KEP-5941**: Shared consumable capacity (proposed for 1.37) -- parent device
  declares capacity consumed by child devices.
- **KEP-5055**: Device taints (alpha) -- health information, evict pods from
  degraded devices.
- **KEP-5729**: Per-PodGroup claims (alpha in 1.37) -- cross-pod topology
  constraints for distributed training.

### Wave 3 -- Transparent Adoption (K8s 1.38+, early design)

Users should not need to know DRA exists.

- **KEP-5004**: Extended resource requests via DRA (P0) -- users write
  `nvidia.com/gpu: 1` without knowing if it is device-plugin or DRA.
- **KEP-5517**: Native resource requests -- CPU/memory as DRA devices.
- **KEP-5677**: Resource availability visibility -- UX for capacity browsing.

## KEP Relevance to This Project

| KEP | Name | Status | Relevance | What It Gives This Project | What It Replaces |
|-----|------|--------|-----------|---------------------------|-----------------|
| 5304 | Attributes Downward API | Alpha, Beta in 1.37 | Critical | Metadata flows to virt-launcher for guest NUMA mapping | Current fork's KEP-5304 consumption |
| 5491 | List Types for Attributes | Alpha in 1.36 | High | Richer topology expression, set-intersection matching | Scalar numaNode/pcieRoot attributes |
| 5075 | Consumable Capacity | Beta in 1.36 | High | Shared device access with capacity tracking (NIC bandwidth, CPU cores) | Manual capacity tracking in coordinator |
| 4815 | Partitionable Devices | Alpha | High | Dynamic GPU partitioning (MIG, CPX) | Static pre-partitioned device lists |
| 5941 | Shared Consumable Capacity | Proposed, 1.37 | High | Cross-device shared resource tracking (PCIe bandwidth, NUMA memory BW) | No current equivalent -- this is a gap |
| 5004 | Extended Resources via DRA | P0 | Medium | Transparent DRA adoption for users | Users rewriting specs for DRA |
| 5729 | ResourceClaim for Workloads | Alpha in 1.37 | Medium | Cross-pod topology constraints for distributed training | Per-pod only topology today |
| 5055 | Device Taints | Alpha | Medium | Device health signaling, eviction | No health tracking currently |
| 4817 | Resource Claim Status | Beta | Medium | Multi-network service identity for NIC VFs | No network identity reporting |
| 5517 | Native Resource Requests | Alpha | Medium (sleeper) | CPU/memory as native DRA -- could eliminate 2 drivers | Separate dra-driver-cpu and dra-driver-memory |
| 4680 | Resource Health in Pod Status | Alpha, Beta | Low-Medium | Health signals in pod status | No pod-level health info |
| 5007 | Binding Conditions | Beta | Low | Scheduling mechanics | N/A |
| 5677 | Resource Availability Visibility | Alpha | Low | UX for capacity browsing | N/A |

## What Replaces the Topology Coordinator

```
TODAY (topology coordinator)          TOMORROW (upstream KEPs)
-------------------------------------  -------------------------------------
5 separate DRA drivers                GPU + NIC drivers only
  (GPU, NIC, CPU, memory, NVMe)         (CPU/memory become native via 5517)

Webhook expands "quarter" -> 4        Scheduler-native partitioning
  claims with matchAttribute            via 4815 + 5075 + 5941
                                        NUMA node = partitionable device

Custom kubelet with DRA               Upstream kubelet
  topology hints                        (topology manager + DRA integration)

enforcement:preferred in fork         Upstream (once proposed)

KEP-5304 alpha in KubeVirt fork       KEP-5304 beta/stable in upstream KubeVirt

Standardized numaNode in forks        resource.kubernetes.io/numaNode upstream

KubeVirt pxb-pcie from DRA            VEP 115 + DRA bridge upstream
```

**Critical gap: Cross-driver resource bundling.** No single KEP addresses "take
one GPU partition, two NIC VFs, 16 CPUs, and 8 GiB from the same NUMA node."

- KEP-4815 partitions within a single device.
- KEP-5075 shares a single device across claims.
- KEP-5941 tracks shared capacity across sibling devices.

But horizontal bundling across 4+ different DRA drivers with topology
constraints remains the topology coordinator's unique value. Standardized
`resource.kubernetes.io/numaNode` combined with multi-driver ResourceClaims
handles the device selection, but over-subscription prevention across drivers
still needs the coordinator or a future KEP.

## KEP-4815 vs KEP-5075: When to Use Which

**KEP-4815 (Partitionable Devices):** Partitions a SINGLE physical device into
overlapping options with shared counters. Use cases: NVIDIA MIG profiles, AMD
CPX mode, TPU slices. The counter set tracks internal resources (memory, compute
units). NOT for cross-driver bundling.

**KEP-5075 (Consumable Capacity):** Shares a SINGLE device across multiple
claims with tracked consumption. Use cases: NIC bandwidth sharing, dynamic VF
creation, CPU core allocation. The device is marked `allowMultipleAllocations`.

| | KEP-5075 (Consumable) | KEP-4815 (Partitionable) |
|---|---|---|
| Sharing model | Same device, multiple claims | Different devices, shared resource pool |
| What is tracked | Capacity consumed from one device | Counters consumed from a counter set |
| Device identity | Claims reference the same device | Claims get different partition devices |
| Use case | NIC bandwidth, CPU time | MIG profiles, CPX mode, TPU slices |
| Isolation | Soft (QoS) | Hard (separate hardware partitions) |

Neither partitions across drivers. NICs do not need KEP-4815 -- VFs are
uniform, SR-IOV creates them, and there is no partition shape decision. GPUs
with MIG/CPX are the primary KEP-4815 use case.

## Timeline

| Timeframe | What Lands Upstream | What Can Be Retired |
|-----------|-------------------|-------------------|
| K8s 1.36 (now) | Consumable capacity beta, list attributes alpha, claim status beta | Nothing yet -- validate against APIs |
| K8s 1.37 (~Aug 2026) | Shared capacity alpha, per-PodGroup claims alpha, KEP-5304 beta, partitionable devices alpha | KEP-5304 fork (switch to upstream beta) |
| K8s 1.38 (~Dec 2026) | Partitionable devices beta, native resources alpha, DRA-via-extended-resources | CPU/memory drivers, custom kubelet patches |
| K8s 1.39+ (2027) | Native resources beta, full topology stack stable | Topology coordinator webhook (replaced by scheduler-native partitioning) |

## References

- [KEP-4381: DRA Structured Parameters](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/4381-dra-structured-parameters)
- [KEP-4680: Resource Health in Pod Status](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/4680-add-resource-health-to-pod-status)
- [KEP-4815: DRA Partitionable Devices](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/4815-dra-partitionable-devices)
- [KEP-4817: DRA Resource Claim Status](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/4817-resource-claim-device-status)
- [KEP-5004: Extended Resources via DRA](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5004-dra-with-classic-resources)
- [KEP-5007: DRA Binding Conditions](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5007-dra-device-conditions)
- [KEP-5055: DRA Device Taints](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5055-scalable-and-consistent-device-taint)
- [KEP-5075: DRA Consumable Capacity](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5075-scalable-dra-consumable-capacity)
- [KEP-5304: DRA Attributes Downward API](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5304-scalable-dra-attributes-downward-api)
- [KEP-5491: List Types for DRA Attributes](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5491-dra-list-types-for-attributes)
- [KEP-5517: Native Resource Requests via DRA](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5517-dra-native-resources)
- [KEP-5677: DRA Resource Availability Visibility](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5677-dra-resource-availability-visibility)
- [KEP-5729: DRA ResourceClaim for Workloads](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5729-dra-resourceclaim-for-workloads)
- [KEP-5941: DRA Shared Consumable Capacity](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5941-dra-shared-consumable-capacity)

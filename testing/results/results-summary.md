# Test Results Summary

**Date:** 2026-04-16
**Hardware:** Dell XE9680 (2-socket, 2 NUMA, 8x MI300X GPUs, 2x ConnectX-6 NICs, 128 CPUs, ~2 TiB RAM)

## Test Progression

| Test | Platform | K8s | Drivers | Result | Date |
|------|----------|-----|---------|--------|------|
| 3-driver NUMA isolation | OCP 4.21 | 1.34.5 | GPU, NIC, CPU | 4-pod quarter split, zero cross-NUMA | 2026-04-09 |
| KubeVirt GPU+NIC VFIO | OCP 4.21 | 1.34.5 | GPU, NIC | VM with 2 guest NUMA nodes (VEP 115) | 2026-04-14 |
| 4-driver full stack | Fedora 43 | 1.36.0-rc.0 | GPU, NIC, CPU, Memory | Quarter + half splits, DRAConsumableCapacity | 2026-04-14 |
| KubeVirt GPU VFIO via DRA | Fedora 43 | 1.36.0-rc.0 | GPU, NIC | KEP-5304 native metadata, VFIO passthrough | 2026-04-14 |
| Topology coordinator partitions | Fedora 43 | 1.36.0-rc.0 | GPU, NIC, CPU, Memory | 8-pod eighth-machine split, webhook expansion | 2026-04-14/15 |
| Full GPU+NIC VFIO with guest NUMA | Fedora 43 | 1.36.0-rc.0 | GPU, NIC | GIM SR-IOV VFs, 7 KubeVirt patches, VEP 115 fix | 2026-04-15/16 |

## Feature Matrix

| Feature | OCP 4.21 (K8s 1.34) | Fedora 43 (K8s 1.36) |
|---------|---------------------|---------------------|
| GPU + NIC NUMA alignment | Yes (3 drivers) | Yes (4 drivers) |
| CPU DRA exclusive pinning | Yes (basic) | Yes (DRAConsumableCapacity) |
| Memory DRA NUMA pinning | No | Yes |
| Hugepages via DRA | No | Yes |
| KEP-5304 metadata | Yes (driver-side) | Yes (native API) |
| DRAConsumableCapacity | No (not available) | Yes (beta) |
| Topology coordinator partitions | Yes (quarter only) | Yes (eighth, quarter, full) |
| KubeVirt GPU VFIO via DRA | Partial (device plugin) | Yes (DRA + KEP-5304) |
| KubeVirt guest NUMA (VEP 115) | Yes (CPU-based only) | Yes (device-aware, patched) |
| Multi-driver metadata | Not tested | Broken (kubelet injects one driver per claim) |

## Patches Required per Platform

| Component | OCP 4.21 Patches | K8s 1.36 Patches | Notes |
|-----------|-----------------|-----------------|-------|
| AMD GPU DRA Driver | 7 | 9 | +VFIO support, +K8s 1.36 API renames |
| SR-IOV NIC DRA Driver | 3 | 5 | +VFIO skip RDMA/CNI |
| DRA CPU Driver | 0 | 0 | Works unpatched |
| DRA Memory Driver | N/A | 2 | Not tested on OCP |
| Topology Coordinator | 4 | 6 | +proportional partitions, +capacity |
| KubeVirt | 2 | 7 | +VEP 115 DRA fix, +VFIO caps |
| containerd | N/A | 1 | Built from main for NRI v0.11.0 |

## Workload Configurations Tested

| Configuration | Pods | Per-Pod Resources | NUMA | Status |
|--------------|------|-------------------|------|--------|
| Quarter-machine (manual CEL) | 4 | 32 CPUs + 2 GPUs + 2 NICs + 128 GiB | Pinned | Working |
| Half-machine (manual CEL) | 2 | 64 CPUs + 4 GPUs + 4 NICs | Pinned | Working |
| Eighth-machine (coordinator) | 8 | 8 CPUs + 1 GPU + 2 NICs + memory | Auto | Working |
| Quarter-machine (coordinator) | 4 | 16 CPUs + 1 GPU + 2 NICs + 8 GiB | Auto | Working |
| Full-machine (coordinator) | 1 | All devices | N/A | Working |
| KubeVirt VM (DRA VFIO) | 1 | 8 vCPUs + 2 GPUs + 2 NICs + 16 GiB hugepages | Guest NUMA | Working (patched) |
| Mixed pod + VM | 2 | Pod: CPUs+NICs, VM: GPUs+NICs | Both | Working |

## Detailed Results

- [OCP 4.21 Baseline Results](ocp421-xe9680.md)
- [K8s 1.36 Full Stack Results](k8s136-fedora43.md)
- [KubeVirt Integration](../../docs/kubevirt-integration.md)
- [Topology Coordinator Partitioning](../../docs/topology-coordinator.md)

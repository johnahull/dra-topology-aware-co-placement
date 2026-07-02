# Topology Coordinator Session — XE9785l MI355X

**Date:** 2026-07-01 through 2026-07-02
**Hardware:** Dell PowerEdge XE9785l, 2× AMD EPYC 9755 (128 cores each), 8× AMD MI355X GPUs, 2× Mellanox ConnectX-6 Dx NICs, ~3 TiB RAM
**Kubernetes:** v1.37.0-alpha.1 (built from commit d03fd8d3b15076)
**System:** NPS4 (8 NUMA nodes), GIM GPU VF passthrough, IOMMU enabled

## What Was Built

### Topology Coordinator Features

| Feature | Status | Description |
|---------|--------|-------------|
| Tier-named aggregates | ✅ Working | `eighth`, `quarter`, `half` based on PCIe root fractions |
| Topology aggregates | ✅ Working | `pcieroot`, `numa`, `full` with short names |
| Intersection approach | ✅ Working | Only drivers on ALL partitions included in aggregates |
| SLIT reachability | ✅ Working | NICs in `numa` aggregate via NUMANodes list equidistance |
| Proportional counts | ✅ Working | 4 VFs / 4 sharing NUMAs = 1 per partition |
| SLIT alignment exclusion | ✅ Working | Reachable-only drivers excluded from pcieRoot alignment |
| Scalar attribute filter | ✅ Working | List-type pcieRoot excluded from matchAttribute constraints |
| pcieRoot list support | ✅ Working | CPU's PCIeRoots []string for alignment matching |
| Capacity enrichment | ✅ Working | NUMA partitions include CPU/memory capacity |
| Code review fixes | ✅ Fixed | Cleanup key mismatch, deduplicated tier logic, package-level map |

### DRA Driver Fixes

| Driver | Fix | Description |
|--------|-----|-------------|
| GPU (AMD) | Rebuilt | Built from local source with VFIO patches against K8s d03fd8d3b15 |
| SR-IOV | Patched | Global config fallback — `VfConfig` with empty `Requests` now applies to all |
| SR-IOV | Containerized | Rebuilt as container image with UBI base + hwdata, deployed via Helm DaemonSet |
| Memory | Blocked | Crashes with "context canceled" when amdgpu blacklisted (port 80 conflict) |

### System Configuration

| Component | Configuration |
|-----------|---------------|
| GIM | Built from MxGPU-Virtualization source for kernel 7.0.12 |
| amdgpu | Blacklisted via modprobe.d + dracut --omit-drivers |
| GPU VFs | 8 created (1 per PF), bound to vfio-pci |
| NIC VFs | 8 created (4 per PF), bound to vfio-pci |
| IOMMU | `amd_iommu=on iommu=pt` in kernel cmdline |
| GPU VFIO config | `kind: VfioDeviceConfig` (apiVersion: gpu.resource.amd.com/v1alpha1) |
| NIC VFIO config | `kind: VfConfig, driver: vfio-pci` (apiVersion: sriovnetwork.k8snetworkplumbingwg.io/v1alpha1) |

## Verified VM Configurations

### 3-NUMA VM with `numa` aggregate (GPU + NIC + CPU + memory)

```
HOST → GUEST MAPPING:

Partition n0:
  GPU   0000:dc:02.0  (Host NUMA 0, pci0000:d0)  →  Guest NUMA 0, fb:00.0
  NIC   0001:07:00.3  (Host NUMA 5, pci0001:00)  →  Guest NUMA 2, fd:00.0
  CPU   cpudevnuma001 (Host NUMA 1, 32 cores)     →  Guest NUMA 0, CPUs 0-3
  MEM   memory-bjd9hw (Host NUMA 2, 378 GiB)      →  Guest NUMA 0, 5.9 GB

Partition n1:
  GPU   0001:dc:02.0  (Host NUMA 4, pci0001:d0)  →  Guest NUMA 1, f7:00.0
  NIC   0001:07:00.4  (Host NUMA 5, pci0001:00)  →  Guest NUMA 2, fe:00.0
  CPU   cpudevnuma002 (Host NUMA 2, 32 cores)     →  Guest NUMA 1, CPUs 4-7
  MEM   memory-t5wtkl (Host NUMA 3, 378 GiB)      →  Guest NUMA 1, 6.0 GB

Partition n2:
  GPU   0001:a5:02.0  (Host NUMA 7, pci0001:a0)  →  Guest NUMA 3, f9:00.0
  NIC   0001:07:00.5  (Host NUMA 5, pci0001:00)  →  Guest NUMA 2, ff:00.0
  CPU   cpudevnuma003 (Host NUMA 3, 32 cores)     →  Guest NUMA 2, CPUs 8-11
  MEM   memory-4qhskf (Host NUMA 4, 378 GiB)      →  Guest NUMA 2, 6.0 GB
```

Guest topology: 3 sockets, 4 NUMA nodes (3 with CPUs, 1 device-only), 12 CPUs, 3 GPU VFs, 3 NIC VFs, ~24 GiB RAM.

NUMA distance matrix:
```
node   0    1    2    3
  0:  10   32   32   32
  1:  32   10   12   12
  2:  32   12   10   12
  3:  32   12   12   10
```

### Aggregate DeviceClasses on this system

| Aggregate | GPU | NIC | CPU | Memory |
|-----------|-----|-----|-----|--------|
| `eighth` | 1 | — | 1 (32 cores) | 1 (378 GiB) |
| `pcieroot` | 1 | — | 1 (32 cores) | 1 (378 GiB) |
| `numa` | 1 | 1 (SLIT) | 1 (32 cores) | 1 (378 GiB) |
| `full` | 8 | 8 | 8 | 8 |

## Commits (branch: feat/both-partitions-and-groupings)

| Commit | Description |
|--------|-------------|
| e9174c5 | feat: add tier-named aggregate DeviceClasses (eighth, quarter, half) |
| 6fcf2dd | fix: repair tier-named DeviceClass cleanup and deduplicate logic |
| 1bb8b03 | fix: pick richest representative for aggregate DeviceClasses |
| 8750f26 | fix: merge device counts across partitions for aggregates |
| d678160 | fix: use intersection of drivers for aggregate DeviceClasses |
| eaaae1f | fix: emit tier names only for pcieroot partitions |
| 84be1b8 | revert: remove SLIT-aware NUMA grouping (needs redesign) |
| 2e5a15e | feat: SLIT-aware reachability for aggregate DeviceClass intersection |
| c3e176e | fix: restrict SLIT reachability to NUMA partitions only |
| ccdee07 | fix: proportional NIC count for SLIT-reachable aggregates |
| d29af94 | fix: exclude SLIT-reachable drivers from pcieRoot alignment |
| 71509c0 | feat: support pcieRoot list-type attributes from CPU driver |
| 7861e9b | fix: don't create pcieRoot partitions from list-type attributes |
| 6078a0c | fix: add capacity enrichment to NUMA partitions |
| 95f7719 | fix: exclude list-type attributes from matchAttribute constraints |

## Known Issues

1. **Memory DRA driver** crashes with "context canceled" when amdgpu is blacklisted — port 80 conflict with stale process
2. **DRA drivers as processes** need systemd services — manual process management is fragile across kubelet/CRI-O restarts
3. **NIC VFs not persistent** — `sriov_numvfs` resets on reboot, needs systemd unit
4. **GPU VFs need GIM** — require amdgpu blacklisted + GIM module loaded + VFs bound to vfio-pci
5. **SR-IOV driver Helm chart** needs container image with hwdata/pciutils for PCI device discovery

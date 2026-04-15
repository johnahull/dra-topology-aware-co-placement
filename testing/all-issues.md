# DRA Topology-Aware Co-Placement — All Issues & Patches

**Platform:** Fedora 43 + K8s 1.36.0-rc.0 on Dell XE9680
**Date:** 2026-04-14/15

---

## Patches Applied

### AMD GPU DRA Driver (`ROCm/k8s-gpu-dra-driver`) — 9 patches

| # | File | Change | Status |
|---|------|--------|--------|
| 1 | `pkg/amdgpu/amdgpu.go` | Fallback `"0.0.0"` when kernel driver version empty | Fixed locally |
| 2 | `cmd/gpu-kubeletplugin/state.go` | Multi-driver claim filter (`result.Driver != consts.DriverName`) | Fixed locally |
| 3 | `cmd/gpu-kubeletplugin/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` + populate Metadata | Fixed locally |
| 4 | `cmd/gpu-kubeletplugin/deviceinfo.go` | Standard `resource.kubernetes.io/pciBusID` attribute in ResourceSlice | Fixed locally |
| 5 | Various | `CDIDeviceIDs` → `CdiDeviceIds` for K8s 1.36 proto | Fixed locally |
| 6 | `api/.../api.go` | `Driver` field in `GpuConfig` for VFIO mode | Fixed locally |
| 7 | `cmd/gpu-kubeletplugin/state.go` | `applyVFIOConfig()` + `bindToVFIO()` + `getIOMMUGroup()` for VFIO passthrough | Fixed locally |
| 8 | `cmd/gpu-kubeletplugin/state.go` + `cdi.go` | VFIO skips common CDI device; `GetClaimDevicesVFIO()` | Fixed locally |
| 9 | `cmd/gpu-kubeletplugin/deviceinfo.go` | Add `dra.net/numaNode` attribute for cross-driver topology coordinator compatibility | Fixed locally |

### SR-IOV NIC DRA Driver (`k8snetworkplumbingwg/dra-driver-sriov`) — 5 patches

| # | File | Change | Status |
|---|------|--------|--------|
| 1 | `pkg/driver/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` | Fixed locally |
| 2 | `pkg/driver/dra_hook.go` | Populate `Metadata` with `resource.kubernetes.io/pciBusID` | Fixed locally |
| 3 | `pkg/devicestate/state.go` | NAD lookup optional for VFIO passthrough | Fixed locally |
| 4 | `pkg/devicestate/state.go` | Skip RDMA for vfio-pci bound devices | Fixed locally |
| 5 | `pkg/nri/nri.go` | Skip CNI attach/detach for VFIO devices | Fixed locally |

### DRA Memory Driver (`kad/dra-driver-memory`) — 2 patches

| # | File | Change | Status |
|---|------|--------|--------|
| 1 | `pkg/sysinfo/preflight.go` | Filter cgroup2 mounts to `/sys/fs/cgroup` (Calico creates second mount at `/run/calico/cgroup`) | Fixed locally |
| 2 | `Dockerfile` | `golang:1.24` → `golang:1.26` for K8s 1.36 | Fixed locally |

### Topology Coordinator (`fabiendupont/k8s-dra-topology-coordinator`) — 6 patches

| # | File | Change | Status |
|---|------|--------|--------|
| 1 | `deviceclass_manager.go` | pcieRoot constraint excludes non-PCI drivers | PR submitted (#1) |
| 2 | `topology_model.go` | `AttrNUMANode` → `dra.net/numaNode` (bug #2: namespace mismatch) | Fixed locally |
| 3 | `deviceclass_manager.go` | `truncateLabel()` for >63 char profile labels (bug #3) | Fixed locally |
| 4 | `deviceclass_manager.go` | Removed cross-driver pcieRoot constraint (GPU/NIC have different PCIe roots) | Fixed locally |
| 5 | `partition_builder.go` + `topology_model.go` | `buildQuarterPartitions()` subdivides NUMA nodes; capacity extraction from ResourceSlice; `divideQuantity()` | Fixed locally |
| 6 | `deviceclass_manager.go` + `webhook.go` | `SubResourceConfig.Capacity` + webhook emits `capacity.requests` for `DRAConsumableCapacity` sharing | Fixed locally |

### KubeVirt (`kubevirt/kubevirt`) — virt-controller patch + virt-launcher wrapper

| # | Component | Change | Status |
|---|-----------|--------|--------|
| 1 | virt-controller (`renderresources.go`) | Skip `permittedHostDevices` check for DRA devices (`ClaimRequest != nil`) | Fixed locally |
| 2 | virt-launcher (Dockerfile wrapper) | Symlink `/var/run/dra-device-attributes` → K8s 1.36 metadata path; dmidecode stub | Fixed locally |

### containerd

| # | Change | Status |
|---|--------|--------|
| 1 | Built from main branch (NRI v0.8.0 → v0.11.0) for memory driver `UpdatePodSandbox` support | Built locally |

---

## Issues to File Upstream

### AMD GPU DRA Driver

| # | Summary | Severity | Repo |
|---|---------|----------|------|
| 1 | Empty `driverVersion` fails ResourceSlice semver validation when kernel amdgpu module doesn't set version | High | `ROCm/k8s-gpu-dra-driver` |
| 2 | `prepareDevices()` doesn't filter by `result.Driver` — fails on multi-driver claims | High | `ROCm/k8s-gpu-dra-driver` |
| 3 | No VFIO passthrough mode — only ROCm containers supported | Medium | `ROCm/k8s-gpu-dra-driver` |
| 4 | Vendor-specific `pciAddr` instead of standard `resource.kubernetes.io/pciBusID` | Medium | `ROCm/k8s-gpu-dra-driver` |
| 5 | No `dra.net/numaNode` attribute — blocks cross-driver topology coordinator | Medium | `ROCm/k8s-gpu-dra-driver` |
| 6 | CDI root defaults to `/etc/cdi`, containerd watches `/var/run/cdi` | Low | `ROCm/k8s-gpu-dra-driver` |
| 7 | gRPC liveness probe fails intermittently → constant pod restarts | Medium | `ROCm/k8s-gpu-dra-driver` |
| 8 | GPU VFIO binding removes PF from discovery — driver can't rediscover after unprepare without restart | High | `ROCm/k8s-gpu-dra-driver` |

### SR-IOV NIC DRA Driver

| # | Summary | Severity | Repo |
|---|---------|----------|------|
| 1 | `PrepareResources` fails without opaque `VfConfig` — no default config for VFIO mode | Medium | `k8snetworkplumbingwg/dra-driver-sriov` |
| 2 | NAD required even for VFIO passthrough (no CNI needed) | High | `k8snetworkplumbingwg/dra-driver-sriov` |
| 3 | RDMA handling fails for vfio-pci bound devices | Medium | `k8snetworkplumbingwg/dra-driver-sriov` |
| 4 | CNI attach/detach runs for VFIO devices (no NAD config) | Medium | `k8snetworkplumbingwg/dra-driver-sriov` |

### Topology Coordinator

| # | Summary | Severity | Repo |
|---|---------|----------|------|
| 1 | pcieRoot constraint includes non-PCI drivers | High | `fabiendupont/k8s-dra-topology-coordinator` |
| 2 | `matchAttribute` uses `nodepartition.dra.k8s.io/numaNode` — no device publishes this namespace | **Critical** | `fabiendupont/k8s-dra-topology-coordinator` |
| 3 | Profile label exceeds 63 chars with 4+ drivers | Medium | `fabiendupont/k8s-dra-topology-coordinator` |
| 4 | Cross-driver pcieRoot constraint unsatisfiable (GPU/NIC have different PCIe roots) | High | `fabiendupont/k8s-dra-topology-coordinator` |
| 5 | No `DRAConsumableCapacity` support — shared devices (CPU, memory) can't be subdivided | High | `fabiendupont/k8s-dra-topology-coordinator` |
| 6 | Quarter partition doesn't subdivide NICs proportionally to GPUs | Medium | `fabiendupont/k8s-dra-topology-coordinator` |
| 7 | No hugepages distinction — `dra.memory` devices treated as interchangeable | Medium | `fabiendupont/k8s-dra-topology-coordinator` |
| 8 | No anti-affinity — scheduler may place all partitions on same NUMA node | Low | Design limitation |

### KubeVirt

| # | Summary | Severity | Repo |
|---|---------|----------|------|
| 1 | `permittedHostDevices` blocks DRA devices (empty `DeviceName`) | High | `kubevirt/kubevirt` |
| 2 | KEP-5304 metadata path mismatch — KubeVirt reads `/var/run/dra-device-attributes/`, K8s 1.36 writes to `/var/run/kubernetes.io/dra-device-attributes/resourceclaims/` | High | `kubevirt/kubevirt` |
| 3 | ACPI not auto-enabled for NUMA VMs — VEP 115 pxb-pcie `_PXM` invisible without `features.acpi` | Medium | `kubevirt/kubevirt` |
| 4 | memfd + VFIO DMA incompatibility — need `kubevirt.io/memfd: "false"` annotation | Medium | `kubevirt/kubevirt` |

### Kubernetes / Kubelet

| # | Summary | Severity | Repo |
|---|---------|----------|------|
| 1 | Multi-driver KEP-5304 metadata in single claim — kubelet only injects metadata CDI mount for one driver | High | `kubernetes/kubernetes` |

### containerd (Fedora packaging)

| # | Summary | Severity |
|---|---------|----------|
| 1 | Fedora 43 containerd 2.1.6 bundles NRI v0.8.0 — DRA memory driver needs v0.11.0 (`UpdatePodSandbox`) | Medium |

### DRA Memory Driver

| # | Summary | Severity | Repo |
|---|---------|----------|------|
| 1 | `ErrCGroupV2Repeated` when Calico creates second cgroup2 mount at `/run/calico/cgroup` | Medium | `kad/dra-driver-memory` |

---

## Summary

| Component | Patches Applied | Issues to File |
|-----------|----------------|---------------|
| AMD GPU DRA driver | 9 | 8 |
| SR-IOV NIC DRA driver | 5 | 4 |
| DRA Memory driver | 2 | 1 |
| Topology coordinator | 6 (+ 1 PR) | 8 |
| KubeVirt | 2 | 4 |
| Kubernetes/kubelet | 0 | 1 |
| containerd | 1 (rebuild) | 1 |
| **Total** | **25 patches** | **27 issues** |

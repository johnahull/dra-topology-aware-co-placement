# DRA Topology-Aware Co-Placement — All Issues & Patches

**Platform:** Fedora 43 + K8s 1.36.0-rc.0 on Dell XE9680
**Date:** 2026-04-14/15

---

## Patches Applied (Upstream Action Required)

### AMD GPU DRA Driver (`ROCm/k8s-gpu-dra-driver`) — 9 patches

| # | File | Change | Upstream Action |
|---|------|--------|-----------------|
| 1 | `pkg/amdgpu/amdgpu.go` | Fallback `"0.0.0"` when kernel driver version empty | **PR needed.** In-kernel `amdgpu` module doesn't set `/sys/module/amdgpu/version`. Both early-return paths in `GetDriverVersion()` return empty string → ResourceSlice semver validation fails. Fix: return `"0.0.0"` as fallback. |
| 2 | `cmd/gpu-kubeletplugin/state.go` | Multi-driver claim filter (`result.Driver != consts.DriverName`) | **PR needed.** `prepareDevices()` iterates ALL `claim.Status.Allocation.Devices.Results` without checking driver name. On multi-driver claims (GPU + CPU + NIC), tries to prepare other drivers' devices → `"requested GPU is not allocatable: cpudevnuma000"`. Fix: skip results where `result.Driver != consts.DriverName`. |
| 3 | `cmd/gpu-kubeletplugin/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` + populate Metadata | **PR needed.** Enable native KEP-5304 metadata API. Populate `kubeletplugin.DeviceMetadata` with `resource.kubernetes.io/pciBusID`, `productName`, `family`, `numaNode` on each device in `PrepareResult`. Requires K8s 1.36+ dependency. |
| 4 | `cmd/gpu-kubeletplugin/deviceinfo.go` | Standard `resource.kubernetes.io/pciBusID` attribute in ResourceSlice | **PR needed.** Driver publishes PCI address as vendor-specific `pciAddr` but not the Kubernetes standard `resource.kubernetes.io/pciBusID`. KubeVirt and KEP-5304 consumers require the standard name. Fix: add the standard attribute alongside the vendor one. One-line change. |
| 5 | Various | `CDIDeviceIDs` → `CdiDeviceIds` for K8s 1.36 proto | **PR needed.** K8s 1.36 `kubelet/pkg/apis/dra/v1beta1` proto renamed fields. Required when updating `k8s.io/kubelet` dependency to v0.36.x. |
| 6 | `api/.../api.go` | `Driver` field in `GpuConfig` for VFIO mode | **PR needed (larger feature).** Add `Driver` field to `GpuConfig` struct to select host driver binding mode (`""` = amdgpu/ROCm default, `"vfio-pci"` = VFIO passthrough). Enables KubeVirt GPU passthrough via DRA. |
| 7 | `cmd/gpu-kubeletplugin/state.go` | `applyVFIOConfig()` + `bindToVFIO()` + `getIOMMUGroup()` for VFIO passthrough | **PR needed (larger feature).** New functions: unbind from amdgpu, bind to vfio-pci via `driver_override`, get IOMMU group from sysfs, create `/dev/vfio/*` CDI device nodes. Note: unstable for PFs — GPU disappears from discovery after unbinding. Needs GIM SR-IOV VF support for production use. |
| 8 | `cmd/gpu-kubeletplugin/state.go` + `cdi.go` | VFIO skips common CDI device; `GetClaimDevicesVFIO()` | **PR needed (part of VFIO feature).** Common CDI device includes `/dev/kfd` which doesn't exist after vfio-pci binding. `GetClaimDevicesVFIO()` returns only the per-claim CDI device, not the common one. |
| 9 | `cmd/gpu-kubeletplugin/deviceinfo.go` | Add `dra.net/numaNode` attribute for cross-driver topology coordinator | **PR or issue needed.** All other DRA drivers publish `dra.net/numaNode` as a compatibility attribute. AMD GPU driver only publishes `gpu.amd.com/numaNode` (vendor namespace). Without `dra.net/numaNode`, the topology coordinator's `matchAttribute` constraint can't align GPUs with CPUs/NICs/memory. Fix: add `dra.net/numaNode` alongside `numaNode` in both full GPU and partition device attributes. |

### SR-IOV NIC DRA Driver (`k8snetworkplumbingwg/dra-driver-sriov`) — 5 patches

| # | File | Change | Upstream Action |
|---|------|--------|-----------------|
| 1 | `pkg/driver/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` | **PR needed.** Enable native KEP-5304 metadata API in `kubeletplugin.Start()`. Requires K8s 1.36+ dependency and `schema.GroupVersion{Group: "metadata.resource.k8s.io", Version: "v1alpha1"}`. |
| 2 | `pkg/driver/dra_hook.go` | Populate `Metadata` with `resource.kubernetes.io/pciBusID` | **PR needed.** Set `kubeletplugin.DeviceMetadata.Attributes` with `resource.kubernetes.io/pciBusID` from `preparedDevice.PciAddress` on each device in `PrepareResult`. Two locations: the "already prepared" path and the "newly prepared" path. |
| 3 | `pkg/devicestate/state.go` | NAD lookup optional for VFIO passthrough | **PR needed.** When `config.NetAttachDefName` is empty, skip `NetworkAttachmentDefinition` lookup. VFIO passthrough doesn't need CNI config — the VF is passed directly as a VFIO device. Without this, `PrepareResources` fails with `"no configs constructed for driver"` for any claim without a NAD. |
| 4 | `pkg/devicestate/state.go` | Skip RDMA for vfio-pci bound devices | **PR needed.** RDMA device entries are removed by the kernel when a VF is bound to `vfio-pci`. The driver's RDMA handling code tries to find RDMA devices at the VF's PCI address and fails. Fix: check `config.Driver != "vfio-pci"` before calling `handleRDMADevice()`. |
| 5 | `pkg/nri/nri.go` | Skip CNI attach/detach for VFIO devices | **PR needed.** In `RunPodSandbox` and `StopPodSandbox`, when `device.NetAttachDefConfig` is empty (VFIO passthrough mode), skip CNI attach/detach. Without this, the NRI plugin tries to unmarshal an empty JSON string as CNI config → `"unexpected end of JSON input"`. On CRI-O, this triggered a `StopPodSandbox` panic (CRI-O bug). |

### DRA Memory Driver (`kad/dra-driver-memory`) — 2 patches

| # | File | Change | Upstream Action |
|---|------|--------|-----------------|
| 1 | `pkg/sysinfo/preflight.go` | Filter cgroup2 mounts to `/sys/fs/cgroup` only | **PR needed.** Calico CNI creates a second cgroup2 mount at `/run/calico/cgroup`. The preflight check counts cgroup2 mounts and errors with `ErrCGroupV2Repeated` when `len(mounts) > 1`. Fix: filter to only `/sys/fs/cgroup` mount point, or accept multiple cgroup2 mounts as valid. |
| 2 | `Dockerfile` | `golang:1.24` → `golang:1.26` | **PR needed.** K8s 1.36 dependencies require Go 1.26+. The Dockerfile hardcodes `golang:1.24`. Should use a build arg or match the go.mod Go version. |

### Topology Coordinator (`fabiendupont/k8s-dra-topology-coordinator`) — 6 patches

| # | File | Change | Upstream Action |
|---|------|--------|-----------------|
| 1 | `deviceclass_manager.go` | pcieRoot constraint excludes non-PCI drivers | **PR submitted (#1).** `matchAttribute: resource.kubernetes.io/pcieRoot` was added for ALL drivers, but CPU/memory drivers don't publish pcieRoot → claims unsatisfiable. Fix: only include drivers that have devices with non-nil PCIeRoot. Includes test. |
| 2 | `topology_model.go` | `AttrNUMANode` → `dra.net/numaNode` | **PR needed.** Coordinator uses `nodepartition.dra.k8s.io/numaNode` as the `matchAttribute` in expanded claims, but NO device from ANY driver publishes attributes in the `nodepartition.dra.k8s.io` domain. All drivers use their own namespaces (`dra.cpu/numaNodeID`, `dra.net/numaNode`, etc.). Fix: use `dra.net/numaNode` which all drivers publish (with AMD GPU driver patch #9). Long-term: use `resource.kubernetes.io/numaNode` when standardized (KEP-5491). |
| 3 | `deviceclass_manager.go` | `truncateLabel()` for >63 char profile labels | **PR needed.** With 4+ drivers, the profile string (e.g., `dra.cpu-2_dra.memory-2_gpu.amd.com-8_sriovnetwork.k8snetworkplumbingwg.io-16`) exceeds the K8s label value limit of 63 characters. DeviceClass creation fails. Fix: `truncateLabel()` uses SHA256 hash suffix when >63 chars. Also fix `sanitizeProfileName()` to preserve partition type suffix when truncating DeviceClass names. |
| 4 | `deviceclass_manager.go` | Removed cross-driver pcieRoot constraint | **PR needed.** The coordinator adds `matchAttribute: resource.kubernetes.io/pcieRoot` across ALL PCI drivers (GPU + NIC). But GPUs and NICs are on different PCIe root complexes → constraint is unsatisfiable. pcieRoot alignment only makes sense for devices of the SAME type (e.g., 2 GPUs under the same switch). Fix: remove cross-driver pcieRoot alignment entirely; NUMA alignment is sufficient. |
| 5 | `partition_builder.go` + `topology_model.go` | `buildQuarterPartitions()` subdivides NUMA nodes; capacity extraction | **PR needed (feature).** The original partition builder creates "quarter" = one NUMA node (which is actually half the machine on 2-socket systems). The fix subdivides each NUMA node by the number of PCIe root groups (e.g., 4 GPUs per NUMA → 4 quarter partitions). Shared devices (CPU, memory) with only 1 device per NUMA get `count: 1` but with proportionally divided capacity. Also extracts `Capacity` from ResourceSlice devices into `TopologyDevice.Capacity`. |
| 6 | `deviceclass_manager.go` + `webhook.go` | `SubResourceConfig.Capacity` + webhook `capacity.requests` | **PR needed (feature).** Adds `Capacity map[string]string` to `SubResourceConfig` so the partition config can carry capacity requirements for shared devices. The webhook reads this and emits `ExactDeviceRequest.Capacity.Requests` in the expanded claim. This enables `DRAConsumableCapacity` sharing — two pods can share the same CPU device with 16 exclusive cores each. |

### KubeVirt (`kubevirt/kubevirt`) — 2 patches

| # | Component | Change | Upstream Action |
|---|-----------|--------|-----------------|
| 1 | virt-controller (`renderresources.go`) | Skip `permittedHostDevices` check for DRA devices | **PR needed.** DRA-provisioned host devices have `ClaimRequest` set but `DeviceName` is empty. The `permittedHostDevices` validation requires a non-empty `DeviceName` and fails with `"HostDevice is not permitted"`. Fix: skip the check when `hostDev.ClaimRequest != nil && hostDev.ClaimName != nil`. DRA devices are validated through the DRA claim mechanism, not permittedHostDevices. |
| 2 | virt-launcher (Dockerfile wrapper) | Symlink for K8s 1.36 KEP-5304 metadata path + dmidecode stub | **PR needed.** K8s 1.36 native KEP-5304 API writes metadata to `/var/run/kubernetes.io/dra-device-attributes/resourceclaims/` but KubeVirt's `DefaultMetadataBasePath` in `pkg/dra/utils.go` points to `/var/run/dra-device-attributes/`. Fix: update `DefaultMetadataBasePath` to the K8s 1.36 path. The current workaround uses a wrapper script that creates a symlink at container startup, plus a dmidecode no-op stub. |

### containerd

| # | Change | Upstream Action |
|---|--------|-----------------|
| 1 | Built from main branch (NRI v0.8.0 → v0.11.0) | **Fedora package bug.** Fedora 43 ships containerd 2.1.6 which bundles NRI v0.8.0. The DRA memory driver uses `containerd/nri v0.11.0` and implements `UpdatePodSandbox` which is not in v0.8.0. containerd immediately closes the ttrpc connection. Fix: update Fedora containerd package to include NRI v0.11.0, or wait for containerd 2.2+ release. Workaround: build containerd from HEAD. |

---

## Issues to File Upstream (Not Yet Patched)

### AMD GPU DRA Driver

| # | Summary | Severity | Details | Repo |
|---|---------|----------|---------|------|
| 1 | GPU VFIO binding removes PF from discovery | High | The driver discovers GPUs via `/sys/module/amdgpu/drivers/`. When a GPU PF is bound to vfio-pci during `PrepareResources`, it disappears from this sysfs path. After `UnprepareResources` rebinds to amdgpu, the driver doesn't re-discover it without a full pod restart. With GIM SR-IOV VFs, this wouldn't be an issue — VFs have their own device IDs and the PF stays on amdgpu. Without GIM, the driver becomes progressively less functional as GPUs are VFIO-bound and unbound. | `ROCm/k8s-gpu-dra-driver` |
| 2 | gRPC liveness probe fails intermittently | Medium | The health check on port 51515 fails after a few minutes, causing the liveness probe to kill the pod. The pod restarts, re-registers with kubelet, but any in-flight `PrepareResources` calls are lost. Workaround: remove the liveness probe from the DaemonSet. Root cause not fully investigated — may be a timeout or resource contention issue. | `ROCm/k8s-gpu-dra-driver` |
| 3 | CDI root defaults to `/etc/cdi` | Low | containerd watches `/var/run/cdi` for CDI spec files. The driver defaults to `--cdi-root=/etc/cdi`. CDI specs written to `/etc/cdi` are invisible to containerd. Must pass `--cdi-root=/var/run/cdi` explicitly. | `ROCm/k8s-gpu-dra-driver` |
| 4 | No GIM SR-IOV VF support | Medium | The driver only discovers and manages physical GPUs (PFs). With GIM creating SR-IOV VFs (device ID `74b5`), the driver would need to discover VFs separately. VFs can be bound to vfio-pci without affecting PF discovery. This is the production path for GPU passthrough to VMs. | `ROCm/k8s-gpu-dra-driver` |

### SR-IOV NIC DRA Driver

| # | Summary | Severity | Details | Repo |
|---|---------|----------|---------|------|
| 1 | No default config for VFIO mode | Medium | `PrepareResources` requires an opaque `VfConfig` in the claim or DeviceClass config. Without it, fails with `"no configs constructed for driver"`. The topology coordinator's webhook expansion doesn't inject driver-specific config. Workaround: add default `VfConfig` with `driver: "vfio-pci"` to the DeviceClass `spec.config`. Upstream fix: create mode-specific DeviceClasses (`sriovnetwork-vfio`, `sriovnetwork-netdev`) with baked-in config, following NVIDIA's pattern. | `k8snetworkplumbingwg/dra-driver-sriov` |

### Topology Coordinator

| # | Summary | Severity | Details | Repo |
|---|---------|----------|---------|------|
| 1 | No hugepages distinction in partitions | Medium | The coordinator treats all `dra.memory` devices as interchangeable. It doesn't distinguish between regular memory devices and hugepages devices. A partition's memory sub-resource may get allocated a hugepages device instead of regular memory, or vice versa. Fix: the partition builder needs DeviceClass-awareness to create separate sub-resources for `dra.memory` and `dra.hugepages-2m`. | `fabiendupont/k8s-dra-topology-coordinator` |
| 2 | No anti-affinity across NUMA | Low | The scheduler may place all partition claims on the same NUMA node (all 4 quarter pods on NUMA 0, leaving NUMA 1 empty). The `matchAttribute: dra.net/numaNode` constraint only requires same-NUMA within each pod, not spread across NUMA nodes. Workaround: add CEL `numaNode==0/1` selectors to claims. DRA has no anti-affinity mechanism. | Design limitation |
| 3 | Partition naming is unintuitive | Low | "Quarter" in the coordinator means "quarter of the device groups within a NUMA node", not "quarter of the machine". With 2 NUMA nodes and 4 GPUs per NUMA, a "quarter" = 1 GPU + 2 NICs + 1 CPU + 1 memory. Users expect "quarter" to mean 25% of the machine (2 GPUs + 4 NICs + 32 CPUs + ...). The naming convention should be documented or made configurable. | `fabiendupont/k8s-dra-topology-coordinator` |
| 4 | Webhook unavailable during controller restart | Medium | The controller pod serves both the reconciler and the webhook. When the pod restarts (e.g., after image update), claims created during the restart window are not expanded by the webhook. They get the raw partition DeviceClass which the scheduler can't allocate. Workaround: wait for the controller pod to be Running before creating claims. Fix: separate webhook and controller pods, or add a readiness gate. | `fabiendupont/k8s-dra-topology-coordinator` |

### KubeVirt

| # | Summary | Severity | Details | Repo |
|---|---------|----------|---------|------|
| 1 | ACPI not auto-enabled for NUMA VMs | Medium | When `vmi.Spec.Domain.Features` is nil (no `features` section in VM spec), `HypervisorFeaturesDomainConfigurator` returns without setting ACPI. VEP 115 pxb-pcie `_PXM` methods need ACPI enabled for guest PCI NUMA visibility. Without it, guest sees `numa_node=-1` for all devices. KubeVirt should auto-enable ACPI when `guestMappingPassthrough` + `PCINUMAAwareTopology` are used. | `kubevirt/kubevirt` |
| 2 | memfd + VFIO DMA incompatibility | Medium | KubeVirt uses `memory-backend-memfd` for hugepages. VFIO DMA mapping fails with `Bad address` when memfd is used. Workaround: `kubevirt.io/memfd: "false"` annotation. KubeVirt should auto-disable memfd when VFIO devices are present. | `kubevirt/kubevirt` |

### Kubernetes / Kubelet

| # | Summary | Severity | Details | Repo |
|---|---------|----------|---------|------|
| 1 | Multi-driver KEP-5304 metadata in single claim | High | When a single ResourceClaim contains devices from multiple DRA drivers (e.g., GPU + NIC), the kubelet's native KEP-5304 API only injects the metadata CDI mount for one driver's devices, not all. The second driver's metadata file exists on the host but is not bind-mounted into the container. Workaround: use separate ResourceClaims per driver. The kubelet plugin framework should inject metadata CDI devices for ALL drivers in a multi-driver claim. | `kubernetes/kubernetes` |

### containerd (Fedora packaging)

| # | Summary | Severity | Details |
|---|---------|----------|---------|
| 1 | NRI v0.8.0 in containerd 2.1.6 | Medium | Fedora 43's containerd 2.1.6 bundles `containerd/nri v0.8.0`. DRA drivers using NRI v0.11.0 features (e.g., `UpdatePodSandbox` in the memory driver) get `ttrpc: server closed` immediately on connection. The upstream containerd main branch has NRI v0.11.0. Workaround: build containerd from HEAD. |

### DRA Memory Driver

| # | Summary | Severity | Details | Repo |
|---|---------|----------|---------|------|
| 1 | NIC VFs not persistent across reboot | Low | SR-IOV VF count (`sriov_numvfs`) resets to 0 on reboot. Not a memory driver issue per se — affects all SR-IOV setups. Need a systemd unit, udev rule, or the SR-IOV operator to persist VF count. | Infrastructure |

---

## Summary

| Component | Patches (PRs needed) | Unfixed Issues | Total |
|-----------|---------------------|----------------|-------|
| AMD GPU DRA driver | 9 | 4 | 13 |
| SR-IOV NIC DRA driver | 5 | 1 | 6 |
| DRA Memory driver | 2 | 0 | 2 |
| Topology coordinator | 6 | 4 | 10 |
| KubeVirt | 2 | 2 | 4 |
| Kubernetes/kubelet | 0 | 1 | 1 |
| containerd | 1 (rebuild) | 1 | 2 |
| Infrastructure | 0 | 1 | 1 |
| **Total** | **25 PRs** | **14 issues** | **39** |

# Proposed Roadmap: VFIO Passthrough and IOMMUFD Support for the AMD GPU DRA Driver

Roadmap for landing VFIO passthrough, IOMMUFD, and related topology features in `ROCm/k8s-gpu-dra-driver`. Organized into three phases: core VFIO support, topology and IOMMUFD, and polish.

## Motivation

KubeVirt VMs require GPU passthrough via VFIO to access AMD Instinct GPUs with near-native performance. The DRA driver needs to manage the full VFIO lifecycle — discovering GPU VFs created by GIM SR-IOV, binding them to `vfio-pci`, generating CDI specs for `/dev/vfio/*` device nodes, and unbinding on release. This enables KubeVirt to allocate GPU resources through the standard Kubernetes DRA API instead of relying on the legacy device-plugin path, which requires GPUs to be pre-bound to `vfio-pci` by the GPU Operator before discovery.

---

## Current State

Feature gate infrastructure merged (PR [#64](https://github.com/ROCm/k8s-gpu-dra-driver/pull/64)). Two PRs are rebased onto `develop` with gates wired in, awaiting re-review:

| PR | Title | Gate | Status |
|---|---|---|---|
| [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | VFIO passthrough for SR-IOV GPU VFs | `VFIOPassthrough` (alpha, off) | Rebased, gate added, all review items addressed. Tested with single-VF-per-GPU (SPX mode) on MI300X and MI355X with GIM SR-IOV and KubeVirt. |
| [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | KEP-5304 device metadata | `DeviceMetadata` (alpha, off) | Rebased, gate added, ready for re-review. |

---

## Phased Roadmap

### Phase 1 — Core VFIO + Metadata (in progress)

| Item | PR | Gate | Status |
|---|---|---|---|
| VFIO passthrough for SR-IOV VFs | [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | `VFIOPassthrough` | Awaiting re-review |
| KEP-5304 device metadata | [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | `DeviceMetadata` | Awaiting re-review |

PRs #50 and #48 are independent — can merge in either order.

### Phase 2 — Topology & IOMMUFD

| Item | Depends on | External blocker |
|---|---|---|
| KEP-4815 partitionable devices (multi-VF + mutual exclusion) | PR #50 | Beta in K8s 1.36 (available now) |
| Standardized `resource.kubernetes.io/numaNode` attribute (KEP-6072) | PR #48 | K8s helper merged ([#139929](https://github.com/kubernetes/kubernetes/pull/139929)), ready to implement |
| IOMMUFD support ([VEP-266](https://github.com/kubevirt/enhancements/issues/266)) | PR #50 | — |

### Phase 3 — Polish

| Item | Depends on |
|---|---|
| VFIO DeviceClass Helm template | PR #50 |
| Webhook validation for `VfioDeviceConfig` | IOMMUFD (Phase 2) |
| Sibling mutual exclusion (PF passthrough only) | PR #50 + PF config bug resolution |
| KubeVirt example manifests | PR #50 |
| GPU Operator convergence | PR #50 validated (separate repo) |

---

## Phase 1 Detail

### VFIO Passthrough (PR [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50))

End-to-end VFIO passthrough for AMD GPUs via DRA. Supports GIM SR-IOV VFs (primary path) and opt-in PF passthrough.

| Component | File | Description |
|---|---|---|
| PCI-level discovery | `pkg/amdgpu/vfio.go` | Scans `/sys/bus/pci/devices/` by AMD vendor ID `0x1002`. GIM VF discovery via `virtfn*` symlinks. IOMMU group detection. PF passthrough (opt-in). |
| VFIO bind/unbind manager | `cmd/gpu-kubeletplugin/vfio_manager.go` | `VfioPciManager` with `Configure()`/`Unconfigure()`. Per-GPU locking. Sysfs `driver_override` writes with cleanup. CDI spec generation for `/dev/vfio/*`. |
| Device type | `cmd/gpu-kubeletplugin/deviceinfo.go` | `AmdGpuVFIOInfo` struct with PCI address, IOMMU group, VF/PF flag, parent PF address. |
| Allocatable extension | `cmd/gpu-kubeletplugin/allocatable.go` | `Vfio *AmdGpuVFIOInfo` field in `AllocatableDevice` union. |
| Prepare/Unprepare | `cmd/gpu-kubeletplugin/state.go` | Type-based dispatch to VFIO config path. On-demand VF binding (`amdgpu` → `vfio-pci`). |
| API type | `api/.../api.go` | `VfioDeviceConfig` kind registered in scheme. |
| Unit tests | `vfio_manager_test.go`, `vfio_test.go` | Tmpdir-backed sysfs for isolated testing. |

### KEP-5304 Device Metadata (PR [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48))

Opts into KEP-5304 device metadata so KubeVirt can read PCI address and NUMA topology from inside the pod.

- `kubeletplugin.EnableDeviceMetadata(true)` when `DeviceMetadata` gate is on
- Populates `DeviceMetadata.Attributes` with `resource.kubernetes.io/pciBusID`, `productName`, `numaNode`
- Works for full GPUs, partitions, and VFIO devices

---

## Phase 2 Detail

### KEP-4815 Partitionable Devices

[KEP-4815](https://github.com/kubernetes/enhancements/issues/4815) (alpha K8s 1.35, beta 1.36) adds DRA support for partitionable devices. Drivers publish a parent device's total capacity as a `SharedCounterSet`, and each partition declares how much it consumes via `consumesCounters`. The scheduler tracks aggregate consumption and prevents over-subscription.

This maps directly to AMD GPU SR-IOV: the PF's total capacity (memory, CU, SIMD) is the counter set, and each GIM VF consumes a fraction. It also handles PF/VF mutual exclusion — if the PF is allocatable as a VFIO device, it consumes all counter slots, preventing co-allocation with any VFs.

**What the driver needs to implement:**

- Publish a `SharedCounterSet` per PF with counters for `memory`, `computeUnits`, `simdUnits` (or a single `vf-slots` counter — design TBD)
- Each VF's `GetDevice()` declares `consumesCounters` for its share of the PF's capacity
- Read `sriov_numvfs` (current active VF count) from sysfs to size the partition model — **not** `sriov_totalvfs` (max supported). With GIM 9.1.0.K multi-VF partition modes, the active count varies by compute partition mode (SPX=1, DPX=2, CPX=8) while `totalvfs` stays fixed at 8. Using `totalvfs` would advertise phantom capacity.
- Derive per-VF capacity (memory, CU, SIMD) by dividing PF totals by VF count — needs a reliable way to read PF-level CU/SIMD capacity from sysfs rather than hardcoding per device ID
- If the partition mode is reconfigured (changing the active VF count), re-publish the counter set and device list with updated capacity
- Unit tests covering discovery and capacity division across partition modes (SPX, DPX, CPX)
- Validation against actual GIM 9.1.0.K DPX (2-VF) and CPX (8-VF) mode output

### Standardized `numaNode` (KEP-6072)

The AMD driver publishes `numaNode` as a bare unqualified attribute. For cross-driver `matchAttribute: resource.kubernetes.io/numaNode` to work (aligning GPUs with NICs, CPUs, and memory from different DRA drivers), all drivers must use the standardized attribute name from [KEP-6072](https://github.com/kubernetes/enhancements/issues/6072) ([KEP PR](https://github.com/kubernetes/enhancements/pull/6073), merged).

Implementation requires calling `deviceattribute.GetNUMANodeAttributeByPCIBusID()` for all device types (GPU, partition, VFIO) in `GetDevice()`. The helper is available in `k8s.io/dynamic-resource-allocation/deviceattribute` as of K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) (merged 2026-07-16). Requires a dependency bump to pick it up.

### IOMMUFD Support

IOMMUFD (Linux 6.2+) enables per-device IOMMU isolation instead of per-group, required for confidential VMs (AMD SEV-SNP) and improved security for multi-device passthrough. See [KubeVirt VEP-266](https://github.com/kubevirt/enhancements/issues/266).

The proposed implementation follows the pattern established by the NVIDIA DRA GPU driver (`kubernetes-sigs/dra-driver-nvidia-gpu`).

**What the driver needs to implement:**

- Add `IOMMUConfig` to the existing `VfioDeviceConfig` API type with two fields: `BackendPolicy` (LegacyOnly or PreferIommuFD) and `EnableAPIDevice` (bool)
- Detect IOMMUFD support at startup by checking for `/dev/iommu`
- Publish `iommuFDEnabled` as a device attribute on VFIO devices in the ResourceSlice
- Extend CDI spec generation: when IOMMUFD is preferred and available, inject `/dev/iommu` + `/dev/vfio/devices/vfioX` instead of the legacy `/dev/vfio/vfio` + `/dev/vfio/<group>`
- Validate `IOMMUConfig` fields in the admission webhook

User-facing config:

```yaml
config:
- opaque:
    driver: gpu.amd.com
    parameters:
      apiVersion: gpu.resource.amd.com/v1alpha1
      kind: VfioDeviceConfig
      iommu:
        backendPolicy: PreferIommuFD
        enableAPIDevice: true
```

---

## Phase 3 Detail

### VFIO DeviceClass Helm Template

Ship `vfio.gpu.amd.com` DeviceClass in the Helm chart, conditional on `featureGates.VFIOPassthrough`:

```yaml
{{- if .Values.featureGates.VFIOPassthrough }}
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: vfio.gpu.amd.com
spec:
  selectors:
  - cel:
      expression: >-
        device.driver == 'gpu.amd.com' &&
        device.attributes['gpu.amd.com'].type == 'amdgpu-vfio'
{{- end }}
```

### Webhook Validation

Wire `VfioDeviceConfig` into the admission webhook (`cmd/webhook/main.go`). Validate `IOMMUConfig.BackendPolicy` enum and `EnableAPIDevice` bool. Depends on IOMMUFD PR landing first.

### Sibling Mutual Exclusion

Prevents the same PCI device from being allocated as both a compute device and a VFIO passthrough device. On prepare, remove the compute sibling from the ResourceSlice; on unprepare, re-discover and re-add it. Only relevant for PF passthrough mode — in the VF case, the PF stays on `amdgpu` and VFs have different PCI addresses, so KEP-4815 partitionable devices (Phase 2) handle the exclusion. Blocked on PF config corruption bug (see below).

### KubeVirt Example Manifests

Example ResourceClaim and VirtualMachine YAML for VFIO GPU passthrough and IOMMUFD configuration.

### GPU Operator Convergence

The GPU Operator currently runs `vfio_bind.sh`/`vfio_unbind.sh` in worker pods for passthrough mode. Once the DRA driver handles VFIO natively, the operator could delegate VFIO binding to the DRA driver for DRA-based workloads. The worker pods are still needed for the legacy device-plugin path, which relies on GPUs being pre-bound to `vfio-pci` before discovery.

---

## Mutual Exclusion: How Sibling Exclusion and KEP-4815 Partitionable Devices Interact

These solve different problems at different levels of the hardware hierarchy:

```
Physical GPU (PCI 0000:c1:00.0)                    Example: CPX mode (8 VFs)
├── gpu-0 (compute, type=amdgpu)          ─┐
│                                           ├── Sibling exclusion (Phase 3)
├── gpu-vfio-0 (PF passthrough, type=vfio) ─┘─┐
│                                              ├── Counter: consumes N/N vf-slots
│   GIM SR-IOV creates N VFs (N=1,2,8):       │
├── gpu-vfio-vf-0 (VF, type=vfio, isVF=true) ─┤── Counter: consumes 1/N vf-slots
├── gpu-vfio-vf-1 (VF, type=vfio, isVF=true) ─┤── Counter: consumes 1/N vf-slots
├── ...                                        │
└── gpu-vfio-vf-(N-1)                         ─┘── Counter: consumes 1/N vf-slots
```

VF count depends on compute partition mode: SPX=1 VF (whole GPU), DPX=2 VFs, CPX=8 VFs.

**Sibling exclusion** prevents the same PCI device from being allocated as both a compute device (`gpu-0` on `amdgpu`) and a passthrough device (`gpu-vfio-0` on `vfio-pci`) at the same time.

**KEP-4815 partitionable devices** prevent over-subscription of VFs from the same PF. If the PF is also allocatable, it consumes all counter slots — making PF passthrough mutually exclusive with any VF allocation.

| Passthrough mode | Sibling exclusion needed? | KEP-4815 needed? |
|---|---|---|
| VF-only (GIM SR-IOV) — **the common case** | No — PF stays on `amdgpu`, VFs are different PCI addresses | Yes — prevents VF over-subscription and PF+VF conflict |
| PF passthrough | Yes — prevents compute + VFIO on same PF | Yes — prevents PF + VF conflict |

For VF-only mode (the primary AMD path), KEP-4815 partitionable devices are sufficient. Sibling exclusion only matters for PF passthrough, which is currently blocked by a hardware issue (see below).

---

## Known Issue: PF Passthrough PCI Config Space Corruption

When an AMD Instinct GPU PF is bound to `vfio-pci` and QEMU resets the device (FLR or bus reset), the PCI config space becomes permanently `0xFF`. The device cannot be recovered via PCI remove+rescan — only a full host reboot recovers it. Observed on MI300X and MI355X.

**Impact:**
- VF passthrough via GIM SR-IOV is **unaffected** and works correctly.
- PF passthrough is gated behind the `VFIOPassthrough` feature gate (PR #50) precisely because of this issue.
- Sibling mutual exclusion (Phase 3) is lower priority because PF passthrough is blocked by this bug.

**Resolution path:** Needs firmware investigation. May require a VFIO reset quirk in the kernel or a firmware fix. Not in scope for the DRA driver — the driver defaults to VF-only mode.

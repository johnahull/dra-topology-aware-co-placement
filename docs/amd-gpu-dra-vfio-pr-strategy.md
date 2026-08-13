# Proposed Roadmap: VFIO Passthrough and IOMMUFD Support for the AMD GPU DRA Driver

Roadmap for landing VFIO passthrough, IOMMUFD, and related topology features in `ROCm/k8s-gpu-dra-driver`. Organized into three phases: core VFIO support, topology and IOMMUFD, and polish.

## Motivation

KubeVirt VMs require GPU passthrough via VFIO to access AMD Instinct GPUs with near-native performance. The DRA driver needs to manage the full VFIO lifecycle — discovering GPU VFs created by GIM SR-IOV, binding them to `vfio-pci`, generating CDI specs for `/dev/vfio/*` device nodes, and unbinding on release. This enables KubeVirt to allocate GPU resources through the standard Kubernetes DRA API instead of relying on the legacy device-plugin path, which requires GPUs to be pre-bound to `vfio-pci` by the GPU Operator before discovery.

---

## Current State

Feature gate infrastructure merged (PR [#64](https://github.com/ROCm/k8s-gpu-dra-driver/pull/64)). KEP-5304 metadata merged. VFIO passthrough awaiting re-review:

| PR | Title | Gate | Status |
|---|---|---|---|
| [#64](https://github.com/ROCm/k8s-gpu-dra-driver/pull/64) | Feature gate infrastructure | — | **Merged.** |
| [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | KEP-5304 device metadata | `DeviceMetadata` (alpha, off) | **Merged 2026-07-27.** Publishes `pciBusID`, `productName`, `numaNode` for all device types. |
| [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | VFIO passthrough for SR-IOV GPU VFs | `VFIOPassthrough` (alpha, off) | All review items addressed. All VFIO code fully gated behind feature flag. Constants consolidated to `pkg/consts`. Restore only on successful Unconfigure. bhatnitish agreed dual-entry (KEP-4815) is a follow-up PR. Tested on MI300X and MI355X. |

---

## Phased Roadmap

### Phase 1 — Core VFIO + Metadata (in progress)

| Item | PR | Gate | Status |
|---|---|---|---|
| KEP-5304 device metadata | [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | `DeviceMetadata` | **Merged 2026-07-27** |
| VFIO passthrough for SR-IOV VFs | [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | `VFIOPassthrough` | Awaiting re-review |

### Phase 2 — Per-VF Capacity & Topology

| Item | Depends on | External blocker |
|---|---|---|
| Per-VF capacity and partition mode attributes | PR #50 | — |
| KEP-4815 partitionable devices + dual-entry + sibling exclusion | Per-VF capacity PR | Beta in K8s 1.36. GIM 9.1.0.K multi-VF support depends on GPU firmware. bhatnitish has a feature incoming that consumes KEP-4815. |
| Standardized `resource.kubernetes.io/numaNode` attribute (KEP-6072) | PR #48 (merged) | Requires `k8s.io/dynamic-resource-allocation` v0.37+ dependency bump. |
| IOMMUFD support ([VEP-266](https://github.com/kubevirt/enhancements/issues/266)) | PR #50 | KubeVirt needs libvirt 12.2+ for IOMMUFD domain XML. |

### Phase 3 — Polish

| Item | Depends on |
|---|---|
| VFIO DeviceClass Helm template | PR #50 |
| Webhook validation for `VfioDeviceConfig` | IOMMUFD (Phase 2) |
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

### Per-VF Capacity and Partition Mode Attributes

**Status:** Not yet PR'd
**Size:** ~120 lines
**Depends on:** PR #50

PR #50 publishes VFIO VFs with attributes (`type`, `numaNode`, `pciAddr`, etc.) but no capacity. Regular AmdGpu devices publish `memory`, `computeUnits`, `simdUnits` — VFIO VFs should too.

**Why this is needed:**
- **Heterogeneous nodes.** A node with MI300X (192GB/VF in SPX) and MI355X (~37GB/VF in CPX) — claims need capacity to distinguish VFs.
- **KEP-4815 prerequisite.** Capacity-based counters require VFs to declare what they consume.
- **Topology coordinator.** Partition DeviceClasses include `capacity` in sub-resources for proportioning.

**What needs to be implemented:**
- Read `sriov_numvfs` (active VF count) and `sriov_totalvfs` from parent PF
- Read PF total memory from sysfs, CU/SIMD from device ID or topology info
- Infer partition mode (SPX/DPX/CPX) from NumVFs and publish as `partitionProfile` attribute
- Divide PF capacity by NumVFs for per-VF `memory`, `computeUnits`, `simdUnits`

---

### KEP-4815 Partitionable Devices

[KEP-4815](https://github.com/kubernetes/enhancements/issues/4815) (alpha K8s 1.35, beta 1.36) adds DRA support for partitionable devices. Drivers publish a parent device's total capacity as a `SharedCounterSet`, and each partition declares how much it consumes via `consumesCounters`. The scheduler tracks aggregate consumption and prevents over-subscription.

This maps directly to AMD GPU SR-IOV: the PF's total capacity (memory, CU, SIMD) is the counter set, and each GIM VF consumes a fraction. It also handles PF/VF mutual exclusion — if the PF is allocatable as a VFIO device, it consumes all counter slots, preventing co-allocation with any VFs.

**Depends on:** Per-VF capacity PR (above) — VFs must publish their capacity before counters can reference it.

**GPU partition mode support (verified 2026-08-04):**

The hardware supports multiple compute/memory partition combinations, but GIM's `vf_num` is limited by what the GPU firmware advertises in `sriov_totalvfs`. On XE9680 MI300X, firmware reports `totalvfs=1` — multi-VF requires a firmware update.

| GPU | NPS1 | NPS2 | NPS4 | Firmware `totalvfs` (XE9680) |
|---|---|---|---|---|
| MI300X | SPX (1 VF) | DPX (2 VFs) | QPX (4 VFs), CPX (8 VFs) | 1 (multi-VF blocked) |
| MI355X | SPX (1 VF), DPX, CPX | — | — | 8 (multi-VF works) |
| MI325X | SPX (1 VF) | untested | untested | untested |

**Note:** AMD docs list MI300X CPX as requiring NPS2, but actual testing shows NPS4 is required (NPS2 only allows DPX). The `available_compute_partition` sysfs file is the authoritative source.

**What the driver needs to implement:**

- Publish a `SharedCounterSet` per PF with counters for `memory`, `computeUnits`, `simdUnits` (or a single `vf-slots` counter — design TBD)
- Each VF's `GetDevice()` declares `consumesCounters` for its share of the PF's capacity
- Read `sriov_numvfs` (current active VF count) from sysfs to size the partition model — **not** `sriov_totalvfs` (max supported). `totalvfs` is firmware-dependent and may be 1 even on GPUs that support multi-VF in hardware (e.g., MI300X on XE9680). `numvfs` reflects the actual VFs created by GIM.
- Derive per-VF capacity (memory, CU, SIMD) by dividing PF totals by VF count — needs a reliable way to read PF-level CU/SIMD capacity from sysfs rather than hardcoding per device ID
- If the partition mode is reconfigured (changing the active VF count), re-publish the counter set and device list with updated capacity
- Unit tests covering discovery and capacity division across partition modes (SPX, DPX, CPX)
- Validation against actual GIM 9.1.0.K DPX (2-VF) and CPX (8-VF) mode output — **requires firmware that supports `totalvfs > 1`**

### Standardized `numaNode` (KEP-6072)

**Status:** Not yet PR'd
**Depends on:** PR #48 (merged)

The AMD driver publishes `numaNode` as a bare unqualified attribute. For cross-driver `matchAttribute: resource.kubernetes.io/numaNode` to work (aligning GPUs with NICs, CPUs, and memory from different DRA drivers), all drivers must use the standardized attribute name from [KEP-6072](https://github.com/kubernetes/enhancements/issues/6072) ([KEP PR](https://github.com/kubernetes/enhancements/pull/6073), merged).

Implementation requires bumping `k8s.io/dynamic-resource-allocation` to v0.37+ and calling `deviceattribute.GetNUMANodeAttributeByPCIBusID()` for all device types (GPU, partition, VFIO) in `GetDevice()`. The helper is available as of K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) (merged 2026-07-16). A `--numa-list` flag controls scalar vs SLIT-based list form for backward compatibility with pre-1.37 clusters.

### IOMMUFD Support

**Status:** Not yet PR'd
**Depends on:** PR #50

IOMMUFD (Linux 6.2+) enables per-device IOMMU isolation instead of per-group, required for confidential VMs (AMD SEV-SNP) and improved security for multi-device passthrough. See [KubeVirt VEP-266](https://github.com/kubevirt/enhancements/issues/266). Follows the NVIDIA DRA GPU driver pattern.

**What the driver needs to implement:**

- Add `IOMMUConfig` to `VfioDeviceConfig` with `BackendPolicy` (LegacyOnly/PreferIommuFD) and `EnableAPIDevice` (bool)
- Detect IOMMUFD at startup via `/dev/iommu`, read cdev name from `vfio-dev/vfioN` after binding
- CDI: `/dev/iommu` + `/dev/vfio/devices/vfioN` (IOMMUFD) vs `/dev/vfio/vfio` + `/dev/vfio/<group>` (legacy)
- VFIO API device (`/dev/vfio/vfio` or `/dev/iommu`) must always be included in CDI spec (libvirt requires it)

**KubeVirt dependency:** KubeVirt v1.9.0 has `IOMMUFDGate` (alpha) but requires libvirt 12.2+ in the virt-launcher image for IOMMUFD-aware domain XML. Current virt-launcher ships libvirt 11.10.

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

### Dual-Entry Advertising and Sibling Mutual Exclusion

**Status:** Not yet PR'd (planned as part of KEP-4815 PR per bhatnitish agreement)

Each compute GPU is advertised as both a compute device (`type=amdgpu`) and a VFIO device (`type=amdgpu-vfio`) in the ResourceSlice. The scheduler explicitly allocates either type. On Prepare, `RemoveSiblingDevices` removes the other type from the ResourceSlice; on Unprepare, `RestoreSiblingDevices` re-adds it. ResourceSlice is republished after each sibling change. Follows the NVIDIA `PerGPUAllocatableDevices` pattern.

### KubeVirt Example Manifests

Example ResourceClaim and VirtualMachine YAML for VFIO GPU passthrough and IOMMUFD configuration.

### GPU Operator Convergence

**Target:** `ROCm/gpu-operator` `develop` (separate repo)

The GPU Operator manages the full GPU lifecycle for passthrough today:

1. **KMM builds and loads GIM** — `kmmmodule.go` compiles `gim.ko` from source via KMM, loads with `modprobe gim`. The `vf_num` parameter comes from the user's `DeviceConfig.spec.driver.kernelModuleConfig.parameters`.
2. **Blacklists `amdgpu`** — for `vf-passthrough` mode, writes `blacklist amdgpu` to `/etc/modprobe.d/` so GIM gets the PF.
3. **Waits for GIM** — init containers poll `/sys/module/gim/drivers/` before starting the DRA plugin.
4. **VFIO bind worker pods** — `workermgr.go` creates pods that run `vfio_bind.sh`/`vfio_unbind.sh` to bind VFs to `vfio-pci` after GIM creates them.

Once the DRA driver handles VFIO natively (PR #50), the VFIO bind worker pods conflict — the operator binds VFs at boot, but the DRA driver expects them unbound for on-demand binding during Prepare.

**What needs to change:**

| Area | Change |
|---|---|
| Skip VFIO bind worker pods | `workermgr.go`: when `draVfioEnabled: true`, skip `vfio_bind.sh`/`vfio_unbind.sh` worker pod creation |
| Pass feature gate to DRA driver | Helm: add `--feature-gates=VFIOPassthrough=true` to DRA driver DaemonSet args |
| Conditional init container | `plugin.go`: for `pf-passthrough` with `draVfioEnabled`, don't wait for `/sys/module/gim/drivers/` |

**What stays the same:** KMM GIM loading, `vf_num` parameter, `amdgpu` blacklisting, DeviceClass creation, CDI spec generation.

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

**Filed:** [`amd/MxGPU-Virtualization` #25](https://github.com/amd/MxGPU-Virtualization/issues/25) (2026-07-27)

When an AMD Instinct GPU PF is bound to `vfio-pci` and QEMU resets the device (FLR or bus reset), the PCI config space becomes permanently `0xFF`. The device cannot be recovered via PCI remove+rescan — only a full host reboot recovers it. Observed on MI300X (device `0x740f`) and MI355X (device `0x75a3`). GIM 9.1.0.K release notes confirm a related VF FLR issue ("SMU FW not responding").

**Workarounds:**
1. **sysfs** (per-device): `echo "" > /sys/bus/pci/devices/<bdf>/reset_method`
2. **Kernel module**: Sets `PCI_DEV_FLAGS_NO_BUS_RESET` on MI355X/MI300X device IDs at load time (source in issue #25)
3. **Proper fix**: PCI quirk in `drivers/pci/quirks.c` for these device IDs (not yet submitted upstream)

With either workaround, PF passthrough works end-to-end (amdgpu → vfio-pci → VM → vfio-pci → amdgpu).

**Impact:**
- VF passthrough via GIM SR-IOV is **unaffected** and works correctly.
- PF passthrough works with the workaround and is gated behind `VFIOPassthrough` (PR #50).
- Sibling mutual exclusion (Phase 3) is lower priority — PF passthrough is functional with workarounds.

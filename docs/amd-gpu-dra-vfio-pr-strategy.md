# Proposed Roadmap: VFIO Passthrough and IOMMUFD Support for the AMD GPU DRA Driver

Roadmap for landing VFIO passthrough, IOMMUFD, and related topology features in `ROCm/k8s-gpu-dra-driver`. Organized into three phases: core VFIO support, topology and IOMMUFD, and polish.

## Motivation

KubeVirt VMs require GPU passthrough via VFIO to access AMD Instinct GPUs with near-native performance. The DRA driver needs to manage the full VFIO lifecycle — discovering GPU VFs created by GIM SR-IOV, binding them to `vfio-pci`, generating CDI specs for `/dev/vfio/*` device nodes, and unbinding on release. This enables KubeVirt to allocate GPU resources through the standard Kubernetes DRA API instead of relying on the legacy device-plugin path, which requires GPUs to be pre-bound to `vfio-pci` by the GPU Operator before discovery.

---

## Current State

Feature gate infrastructure merged (PR [#64](https://github.com/ROCm/k8s-gpu-dra-driver/pull/64)). KEP-5304 metadata merged. VFIO passthrough merged. Phase 1 complete:

| PR | Title | Gate | Status |
|---|---|---|---|
| [#64](https://github.com/ROCm/k8s-gpu-dra-driver/pull/64) | Feature gate infrastructure | — | **Merged.** |
| [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | KEP-5304 device metadata | `DeviceMetadata` (alpha, off) | **Merged 2026-07-27.** Publishes `pciBusID`, `productName`, `numaNode` for all device types. |
| [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | VFIO passthrough for SR-IOV GPU VFs | `VFIOPassthrough` (alpha, off) | **Merged 2026-08-14.** VF discovery from GIM-managed PFs, vfio-pci binding, CDI specs. Tested on MI300X (XE9680) and MI355X (XE9785L). |
| [#88](https://github.com/ROCm/k8s-gpu-dra-driver/pull/88) | Auto-partition (dynamic GPU repartitioning) | `AutoPartition` (alpha, off) | bhatnitish's PR. Repartitions GPUs via amd-smi at Prepare time. Uses KEP-4815 mutex counters for one-mode-per-GPU. Compute-only (no VFIO). Hardware-validated on 8×MI300X. |

### Related Issues

| Issue | Title | Status |
|---|---|---|
| [#89](https://github.com/ROCm/k8s-gpu-dra-driver/issues/89) | KEP-4815 dual-entry advertising for VFIO | Branch ready (`feature/kep4815-dual-entry-v2`), PR pending. Combines per-VF capacity + KEP-4815 dual-entry + sibling exclusion + unit tests + bug fixes. |
| [#90](https://github.com/ROCm/k8s-gpu-dra-driver/issues/90) | Dynamic GPU repartitioning with VFIO passthrough | Open. Combines PR #50 + #88. Blocked on GIM hot-reconfiguration. |

---

## Phased Roadmap

### Phase 1 — Core VFIO + Metadata (complete)

| Item | PR | Gate | Status |
|---|---|---|---|
| KEP-5304 device metadata | [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | `DeviceMetadata` | **Merged 2026-07-27** |
| VFIO passthrough for SR-IOV VFs | [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | `VFIOPassthrough` | **Merged 2026-08-14** |

### Phase 2 — Per-VF Capacity & Topology

| Item | Depends on | Status |
|---|---|---|
| Per-VF capacity and partition mode attributes | PR #50 | **Implemented** on `feature/kep4815-dual-entry-v2`. [PR #91](https://github.com/ROCm/k8s-gpu-dra-driver/pull/91). |
| KEP-4815 dual-entry + sibling exclusion | Per-VF capacity | **Implemented** on `feature/kep4815-dual-entry-v2`. [PR #91](https://github.com/ROCm/k8s-gpu-dra-driver/pull/91). |
| Standardized `resource.kubernetes.io/numaNode` attribute (KEP-6072) | PR #48 (merged) | [#92](https://github.com/ROCm/k8s-gpu-dra-driver/issues/92). Blocked on `k8s.io/dynamic-resource-allocation` v0.37+ bump. |
| IOMMUFD support ([VEP-266](https://github.com/kubevirt/enhancements/issues/266)) | PR #50 | [#93](https://github.com/ROCm/k8s-gpu-dra-driver/issues/93). Blocked on KubeVirt libvirt 12.2+. |

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

**Status:** Implemented on `feature/kep4815-dual-entry-v2` (PR pending, issue #89)
**Depends on:** PR #50

PR #50 publishes VFIO VFs with attributes (`type`, `numaNode`, `pciAddr`, etc.) but no capacity. Regular AmdGpu devices publish `memory`, `computeUnits`, `simdUnits` — VFIO VFs should too.

**Why this is needed:**
- **Heterogeneous nodes.** A node with MI300X (192GB/VF in SPX) and MI355X (~37GB/VF in CPX) — claims need capacity to distinguish VFs.
- **KEP-4815 prerequisite.** Capacity-based counters require VFs to declare what they consume.
- **Topology coordinator.** Partition DeviceClasses include `capacity` in sub-resources for proportioning.

**What was implemented:**
- `ReadSRIOVNumVFs()` reads `sriov_numvfs` (active VF count) from parent PF sysfs
- `ReadPFCapacity()` reads PF total memory from `mem_info_vram_total`, CU/SIMD from `gpuCapacityByDeviceID()` lookup (MI300X, MI355X, MI325X)
- `partitionMode()` infers SPX/DPX/QPX/CPX from NumVFs, published as `partitionProfile` attribute (e.g., `cpx_nps1`)
- Per-VF capacity: PF totals divided by NumVFs for `memory`, `computeUnits`, `simdUnits`
- VFIO siblings for compute GPUs (dual-entry PFs) advertise full PF capacity
- Unit tests for all new functions (partition mode, capacity, sysfs helpers)

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

**What was implemented** (on `feature/kep4815-dual-entry-v2`):

- `SharedCounterSet` per PF with a single `vf-slots` counter (value = `TotalVFs`). Counter sets are deduplicated per PF address in `collectVFIOCounterSets()`.
- Each VF's `GetDevice()` declares `ConsumesCounters`: VFs consume 1 slot, PFs consume all slots (mutual exclusion).
- Non-SR-IOV GPUs (`ReadSRIOVTotalVFs` returns 0) get `TotalVFs=0` and no counter set — counter logic only activates for GPUs with actual SR-IOV capability.
- `ReadSRIOVNumVFs` reads active VF count. `ReadPFCapacity` reads PF totals. Per-VF capacity = PF totals / NumVFs.
- Unit tests for counter sets, consumption, partition mode, sysfs helpers.

**Still needs:**
- Hardware validation against GIM 9.1.0.K DPX (2-VF) and CPX (8-VF) mode — **requires firmware that supports `totalvfs > 1`**
- Dynamic repartitioning (changing VF count at runtime) — blocked on GIM hot-reconfiguration (issue #90)

### Dual-Entry Advertising and Sibling Mutual Exclusion

**Status:** Implemented on `feature/kep4815-dual-entry-v2` (PR pending, issue #89)

Each compute GPU is advertised as both a compute device (`type=amdgpu`) and a VFIO device (`type=vfio`) in the ResourceSlice. The scheduler explicitly allocates either type. On Prepare, `RemoveSiblingDevices` removes the other type from the ResourceSlice; on Unprepare, `RestoreSiblingDevices` re-adds it. ResourceSlice is republished after each sibling change via `republishResources()`. Follows the NVIDIA `PerGPUAllocatableDevices` pattern.

**Implementation details:**
- `RemoveSiblingDevices` takes an explicit map key parameter (not `CanonicalName()`) to correctly handle on-demand VFIO conversion where the device type changes in-place
- `republishResources` acquires the state lock while building the resources snapshot, preventing data races with concurrent Prepare/Unprepare
- VFIO VFs (`IsVF=true`) return `""` from `GetSiblingLookupPCIAddress()` — they have different PCI addresses from the PF, so sibling exclusion does not apply to VFs
- Sibling removal happens before checkpoint write; rollback restores siblings if checkpoint fails
- Unit tests cover sibling removal/restoration, PCI index construction, capacity preservation, and edge cases (no siblings, empty cache)

### Bug Fixes Found During Code Review (2026-08-19)

Three bugs were found and fixed during architect + code review of the combined branch:

1. **Data race in `republishResources`** — `buildDriverResources` iterated `d.state.allocatable` without holding the state lock while concurrent `Prepare`/`Unprepare` calls mutated the map (via `delete` in `RemoveSiblingDevices` and insert in `RestoreSiblingDevices`). Go's concurrent map read+write causes a runtime panic. Fixed by acquiring the state lock in `republishResources` while building the snapshot.

2. **VFIO conversion name mismatch in `RemoveSiblingDevices`** — After on-demand VFIO conversion (VfioDeviceConfig on a compute GPU), the device's `CanonicalName()` changed from `gpu-0-128` to `gpu-vfio-0`, but the device remained in `allocatable` under the original key. `RemoveSiblingDevices` used `CanonicalName()` to exclude the prepared device from removal — with the wrong name, it deleted the prepared device itself and kept the sibling. Fixed by passing the map key as an explicit parameter.

3. **Spurious counter sets for non-SR-IOV GPUs** — `max(ReadSRIOVTotalVFs, 1)` forced `TotalVFs=1` for GPUs without SR-IOV, creating a pointless `SharedCounterSet` with 1 slot. Fixed by using `ReadSRIOVTotalVFs` directly; non-SR-IOV GPUs get `TotalVFs=0` and no counter set.

---

### Standardized `numaNode` (KEP-6072)

**Status:** Issue [#92](https://github.com/ROCm/k8s-gpu-dra-driver/issues/92) filed. Blocked on dep bump.
**Depends on:** PR #48 (merged)

The AMD driver publishes `numaNode` as a bare unqualified attribute. For cross-driver `matchAttribute: resource.kubernetes.io/numaNode` to work (aligning GPUs with NICs, CPUs, and memory from different DRA drivers), all drivers must use the standardized attribute name from [KEP-6072](https://github.com/kubernetes/enhancements/issues/6072) ([KEP PR](https://github.com/kubernetes/enhancements/pull/6073), merged).

Implementation requires bumping `k8s.io/dynamic-resource-allocation` to v0.37+ and calling `deviceattribute.GetNUMANodeAttributeByPCIBusID()` for all device types (GPU, partition, VFIO) in `GetDevice()`. The helper is available as of K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) (merged 2026-07-16). A `--numa-list` flag controls scalar vs SLIT-based list form for backward compatibility with pre-1.37 clusters.

### IOMMUFD Support

**Status:** Issue [#93](https://github.com/ROCm/k8s-gpu-dra-driver/issues/93) filed. Blocked on KubeVirt libvirt 12.2+.
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
        device.attributes['gpu.amd.com'].type == 'vfio'
{{- end }}
```

### Webhook Validation

Wire `VfioDeviceConfig` into the admission webhook (`cmd/webhook/main.go`). Validate `IOMMUConfig.BackendPolicy` enum and `EnableAPIDevice` bool. Depends on IOMMUFD PR landing first.

### KubeVirt Example Manifests

Example ResourceClaim and VirtualMachine YAML for VFIO GPU passthrough and IOMMUFD configuration.

### GPU Operator Convergence

**Target:** `ROCm/gpu-operator` `develop` (separate repo)
**Status:** Analysis complete (2026-08-20). No issue filed yet.

The GPU Operator manages the full GPU lifecycle for passthrough today:

1. **KMM builds and loads GIM** — `kmmmodule.go` compiles `gim.ko` from source via KMM, loads with `modprobe gim`. The `vf_num` parameter comes from the user's `DeviceConfig.spec.driver.kernelModuleConfig.parameters` and determines partition mode (1=SPX, 2=DPX, 3=TPX, 4=QPX, 8=CPX).
2. **Blacklists `amdgpu`** — `nodelabeller.go` writes `blacklist amdgpu` to `/etc/modprobe.d/` for `vf-passthrough` mode so GIM gets the PF directly.
3. **Waits for GIM** — init containers in `plugin.go` poll `/sys/module/gim/drivers/` before starting the device plugin.
4. **VFIO bind worker pods** — `node.go` triggers `workerMgr.Work()` which creates pods running `vfio_bind.sh` to pre-bind all VFs to `vfio-pci` at boot.

**Conflict with DRA VFIO:** The DRA driver (PR #50) handles VFIO binding on-demand during Prepare and expects VFs unbound. Dual-entry advertising (PR #91) requires `amdgpu` to be loaded for compute GPU discovery. Both conflict with the operator's current flow.

**What needs to change:**

| Area | File | Change |
|---|---|---|
| Add DRA VFIO config flag | `api/v1alpha1/deviceconfig_types.go` | Add `VFIOEnabled bool` to `DRADriverSpec`. Controls all items below. |
| Skip VFIO bind worker pods | `internal/controllers/watchers/node.go` (line 233) | When `DRADriverSpec.VFIOEnabled`: skip `workerMgr.Work()`. DRA binds on demand. |
| Do NOT blacklist amdgpu | `internal/nodelabeller/nodelabeller.go` | When `DRADriverSpec.VFIOEnabled`: skip blacklist. `amdgpu` must load for dual-entry compute discovery. |
| Pass VFIOPassthrough gate | `internal/plugin/plugin.go` | Add `--feature-gates=VFIOPassthrough=true` to DRA driver DaemonSet args. |
| Wait for GIM in DRA init | `internal/plugin/plugin.go` (line 330) | DRA init container waits for `amdgpu` only. Add GIM wait (`/sys/module/gim/drivers/`) when VF passthrough + DRA VFIO. |

**New flow with DRA VFIO enabled:**
1. `amdgpu` loads and binds PFs (compute discovery works)
2. KMM loads GIM on top with `vf_num` (VFs created)
3. DRA driver init waits for both `amdgpu` and GIM
4. DRA discovers compute GPUs + GIM VFs, advertises dual-entry (`type=amdgpu` + `type=vfio`)
5. On Prepare: DRA binds specific VF to `vfio-pci`
6. On Unprepare: DRA unbinds back to original driver

**What stays the same:**
- KMM GIM loading with `vf_num` parameter (DRA needs GIM for VF creation)
- `vf_num` is admin-configured in DeviceConfig CRD
- VFIO unbind script (for cleanup when DRA driver is removed)
- Node labelling (driver type labels still useful)

---

## Mutual Exclusion: How Sibling Exclusion and KEP-4815 Partitionable Devices Interact

These solve different problems at different levels of the hardware hierarchy:

```
Physical GPU (PCI 0000:c1:00.0)                    Example: CPX mode (8 VFs)
├── gpu-0 (compute, type=amdgpu)          ─┐
│                                           ├── Sibling exclusion (Phase 2)
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
- Sibling mutual exclusion (Phase 2, part of KEP-4815 PR) is lower priority — PF passthrough is functional with workarounds.

# AMD GPU DRA Driver — VFIO/IOMMUFD PR Strategy

PR plan for landing VFIO passthrough and IOMMUFD support in `ROCm/k8s-gpu-dra-driver`. Based on review feedback from bhatnitish and yansun1996, existing branch work, and the NVIDIA DRA driver as reference implementation.

**Last updated:** 2026-07-15

---

## Current State

### Existing Branches (all rebased onto `develop`)

```
feature/multi-vf-partitions          ← GIM 9.1.0.K multi-VF (1/2/8) partition mode + per-VF capacity
  └─ feature/vfio-passthrough-v2     ← core VFIO + on-demand binding + PF passthrough + VFIOPassthrough gate
       └─ develop                    ← feature gate infra (PR #64, merged) + Go 1.26.5 security fix

feature/vfio-kep4815-counters        ← superset: VFIO + counters + metadata + numa-list + both gates
  └─ develop

feat/kep5304-device-metadata-v2      ← KEP-5304 metadata + DeviceMetadata gate
  └─ develop
```

### Open PRs

| PR | Title | Status | Reviewer Feedback |
|---|---|---|---|
| [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | VFIO passthrough for SR-IOV GPU VFs | LGTM (yansun1996), rebased onto `develop`, `VFIOPassthrough` feature gate added | Approved after feature gate integration. PF passthrough tested end-to-end on MI355X. |
| [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | KEP-5304 device metadata | Rebased onto `develop`, `DeviceMetadata` feature gate added | Ready for re-review. |
| [#64](https://github.com/ROCm/k8s-gpu-dra-driver/pull/64) | Feature gate mechanism | **Merged** into `develop` | Provides the gate infra used by PRs #50 and #48. |

### Key Reviewer Requirements — All Addressed

1. ~~**Target `develop` branch**~~ — Done. Both PRs rebased onto `develop`.
2. ~~**Feature gate infrastructure**~~ — Done. PR #64 merged. Both features gated.
3. ~~**`make check` / `go fmt` clean**~~ — Done. All branches pass `go build`, `go vet`, `go test`.

---

## PR Sequence

```
PR 0:  Feature gate infra (#64)                    ✅ MERGED
  │
  ├── PR 1:  VFIO passthrough (#50)                ✅ VFIOPassthrough gate added, LGTM
  │    │
  │    ├── PR 4.5: Multi-VF partition modes         code complete, not PR'd yet
  │    ├── PR 5:  KEP-4815 counters                gate: VFIOPassthrough  (K8s 1.37+)
  │    ├── PR 6:  VFIO DeviceClass Helm template   gate: VFIOPassthrough
  │    ├── PR 8:  Sibling mutual exclusion          PF passthrough only (workaround exists)
  │    └── PR 9:  KubeVirt example manifests
  │
  └── PR 2:  KEP-5304 metadata (#48)               ✅ DeviceMetadata gate added
       │
       └── PR 3:  Standardized numaNode (D-8)      blocked on K8s #139929
             │
             └── PR 4:  IOMMUFD support             gate: VFIOPassthrough
                   │
                   └── PR 7:  Webhook validation for VfioDeviceConfig
```

```
PR 10: GPU Operator convergence                    separate repo (ROCm/gpu-operator)
```

PR 1 and PR 2 are independent of each other — can merge in either order (PR 0 already merged).
PR 4.5 (multi-VF) extends PR 1 with GIM 9.1.0.K support for 2-VF DPX mode.

---

### PR 0: Feature Gate Infrastructure — MERGED (#64)

**Status:** ✅ Merged into `develop` (2026-07-13)
**Author:** johnahull

Adds `pkg/featuregates/featuregates.go` with versioned gate registry, `pkg/flags/featuregates.go` with CLI/env wiring (`--feature-gates`, `FEATURE_GATES`), and Helm `featureGates` map support. Both PRs #50 and #48 now use this infrastructure.

---

### PR 1: VFIO Passthrough (#50) — Ready for Merge

**Status:** ✅ Rebased onto `develop`, feature gate added, LGTM from yansun1996
**Branch:** `feature/vfio-passthrough-v2`
**Target:** `develop`
**Gate:** `VFIOPassthrough` (alpha, default false)
**Tested on:** XE9680 (MI300X), XE9785L (MI355X)

All rework complete:
- ✅ Rebased onto `develop`
- ✅ `--enable-pf-passthrough` replaced with `VFIOPassthrough` feature gate
- ✅ PF passthrough tested end-to-end (amdgpu→vfio-pci→amdgpu cycle)
- ✅ On-demand VFIO binding for VFs (amdgpu→vfio-pci when VfioDeviceConfig present)
- ✅ `go build`, `go vet`, `go test` all pass

---

### PR 2: KEP-5304 Device Metadata (#48) — Ready for Re-review

**Status:** ✅ Rebased onto `develop`, `DeviceMetadata` feature gate added
**Branch:** `feat/kep5304-device-metadata-v2`
**Target:** `develop`
**Gate:** `DeviceMetadata` (alpha, default false)

All rework complete:
- ✅ Rebased onto `develop`
- ✅ `kubeletplugin.EnableDeviceMetadata(true)` gated behind `DeviceMetadata` feature gate
- ✅ Metadata attribute population gated
- ✅ `go build`, `go vet`, `go test` all pass

**Note:** Independent of PR 1. Can merge before or after VFIO.

---

### PR 3: Standardized `numaNode` Attribute (D-8)

**Status:** Code complete in `feature/standardized-topology-attrs`. Blocked on K8s dependency.
**Target:** `develop`
**Size:** ~50-100 lines (driver change is small; dependency bump is the bulk)
**Depends on:** K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) (provides `GetNUMANodeAttributeByPCIBusID` helper)
**Branch:** `johnahull/k8s-gpu-dra-driver` `feature/standardized-topology-attrs`

The AMD driver publishes `numaNode` as a bare unqualified attribute. Other drivers publish vendor-specific names (`gpu.nvidia.com/numa`, `dra.cpu/numaNodeID`, `dra.net/numaNode`). For `matchAttribute: resource.kubernetes.io/numaNode` to align devices across drivers, all must use the standardized name from KEP-6072.

**What's already implemented (in fork):**
- Publishes `resource.kubernetes.io/numaNode` (via `deviceattribute.GetNUMANodeAttributeByPCIBusID()`) alongside the bare `numaNode` for all device types (GPU, partition, VFIO)
- Publishes `resource.kubernetes.io/cpuSocketID` for socket-level topology
- VFIO devices get the same standardized attributes

**What's needed to upstream:**
1. K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) must merge (provides the helper in `k8s.io/dynamic-resource-allocation/deviceattribute`)
2. Bump `k8s.io/dynamic-resource-allocation` dependency in `k8s-gpu-dra-driver` to pick up the helper
3. PR against `develop` — call the standardized helper for all device types in `GetDevice()`

**Can ship independently** of the VFIO PRs (affects all device types, not just VFIO). Sequenced here after PR 2 because KEP-5304 metadata is how `numaNode` reaches the workload at runtime.

**Sequencing with VFIO PRs:**
- The `feature/vfio-kep5304-combined` branch already includes the standardized numaNode for VFIO devices, but this depends on the K8s helper being available in the vendored dependency.
- If K8s #139929 merges before PR 1, include standardized numaNode in PR 1. If not, ship PR 1 with bare `numaNode` and add standardized form in this PR when the dependency is available.

---

### PR 4: IOMMUFD Support (new — D-18)

**Status:** Not started
**Target:** `develop`
**Size:** ~300-400 lines estimated
**Depends on:** PR 1 (extends VFIO CDI handler)
**Gate:** `VFIOPassthrough` (same gate — IOMMUFD is part of the VFIO feature)
**Reference:** NVIDIA DRA driver `cmd/gpu-kubelet-plugin/vfio-cdi.go`, [KubeVirt VEP 266](https://github.com/kubevirt/enhancements/issues/266)

**What to build:**

| File | Change |
|---|---|
| `api/.../vfioconfig.go` or extend `api.go` | Add `IOMMUConfig` fields to `VfioDeviceConfig`: `BackendPolicy` (LegacyOnly/PreferIommuFD), `EnableAPIDevice` (bool) |
| `api/.../iommu.go` (new) | `IOMMUConfig` type, `IOMMUBackendPolicy` enum, helper methods `ShouldPreferIommuFD()`, `ShouldEnableAPIDevice()` |
| `pkg/amdgpu/vfio.go` | Add `CheckIommuFDEnabled()` — check `/dev/iommu` exists |
| `cmd/gpu-kubeletplugin/deviceinfo.go` | Add `IommuFDEnabled bool` to `AmdGpuVFIOInfo`, publish as device attribute |
| `cmd/gpu-kubeletplugin/vfio_manager.go` | Extend CDI spec generation: when `PreferIommuFD` and IOMMUFD available, inject `/dev/iommu` + `/dev/vfio/devices/vfioX` instead of `/dev/vfio/vfio` + `/dev/vfio/<group>` |
| `cmd/gpu-kubeletplugin/state.go` | Pass `IOMMUConfig` from `VfioDeviceConfig` into CDI generation |
| `api/.../validate.go` | Validate `VfioDeviceConfig.Iommu` fields |

**NVIDIA reference (exact pattern to follow):**
- `vfio-cdi.go:53` `GetCommonEdits(enableAPIDevice, preferIommuFD bool)` — always includes `/dev/vfio/vfio`, optionally `/dev/iommu`
- `vfio-cdi.go:91` `GetDeviceSpecsByPCIBusID(pciBusID, preferIommuFD bool)` — IOMMUFD: `/dev/vfio/devices/<cdev>`; legacy: `/dev/vfio/<group>`
- `iommu.go:42` `IOMMUConfig` struct with `BackendPolicy` and `EnableAPIDevice`

**User-facing config:**
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

### PR 4.5: Multi-VF Partition Mode Support (new)

**Status:** Code complete in `feature/multi-vf-partitions`. Not yet PR'd.
**Branch:** `feature/multi-vf-partitions` (based on `feature/vfio-passthrough-v2`)
**Target:** `develop`
**Size:** ~120 lines
**Depends on:** PR 1

Support for GIM 9.1.0.K multi-VF configurations:
- **1 VF** (SPX) — full GPU in a single VF
- **2 VFs** (DPX) — 4 XCCs per VF (new in GIM 9.1.0.K for MI355X/MI350X)
- **8 VFs** (CPX) — 1 XCC per VF

**What's implemented:**

| Component | File | Change |
|---|---|---|
| `ReadSRIOVNumVFs()` | `pkg/amdgpu/vfio.go` | Read active VF count from parent PF |
| `ReadPFCapacity()` | `pkg/amdgpu/vfio.go` | Read PF memory from sysfs, CU/SIMD from device ID lookup |
| `NumVFs`, `TotalVFs` on VFInfo | `pkg/amdgpu/vfio.go` | Propagated from parent PF during discovery |
| `partitionMode()` | `cmd/gpu-kubeletplugin/deviceinfo.go` | Infers SPX/DPX/QPX/CPX from NumVFs |
| `partitionProfile` attribute | `cmd/gpu-kubeletplugin/deviceinfo.go` | Published on VFIO devices (e.g., `cpx_nps1`) |
| Per-VF capacity | `cmd/gpu-kubeletplugin/deviceinfo.go` | `memory`, `computeUnits`, `simdUnits` = PF capacity / NumVFs |
| VF discovery | `cmd/gpu-kubeletplugin/discovery.go` | Propagates NumVFs, TotalVFs, ParentPFAddress, per-VF capacity |

**Partition mode → Topology coordinator tier mapping:**
- SPX (1 VF) = `full` — 8/8 PCIe roots
- DPX (2 VFs) = `half` — 4/8 PCIe roots
- CPX (8 VFs) = `eighth` — 1/8 PCIe roots

---

### PR 5: KEP-4815 Counter Sets (new)

**Status:** Code complete in `feature/vfio-kep4815-counters`. Needs rebase.
**Target:** `develop`
**Size:** ~350 lines
**Depends on:** PR 1
**Gate:** `VFIOPassthrough` (same gate)
**K8s dependency:** KEP-4815 `SharedCounters` API — requires K8s 1.37+

**What's already implemented:**

- `collectVFIOCounterSets()` — creates one `SharedCounters` per PF, sized to the VF count
- `GetSharedCounterSet()` on `AmdGpuVFIOInfo` — generates counter set named after PF PCI address
- Separate ResourceSlices for counters vs devices when the API requires it
- PF/VF mutual exclusion: allocating a VF decrements the PF's counter, preventing over-subscription

**Rework needed:**

1. Rebase onto `develop` with PR 1 merged
2. Gate behind `VFIOPassthrough`
3. May need to wait for K8s 1.37 GA if counter API is still alpha

---

### PR 6: VFIO DeviceClass Helm Template

**Status:** Not started
**Target:** `develop`
**Size:** ~20 lines
**Depends on:** PR 1

Add `helm-charts-k8s/templates/deviceclass-vfio.yaml`:

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

Conditional on `featureGates.VFIOPassthrough` so it's not created when VFIO is disabled.

---

### PR 7: Webhook Validation for VfioDeviceConfig

**Status:** Not started
**Target:** `develop`
**Size:** ~50-100 lines
**Depends on:** PR 4 (when `IOMMUConfig` fields land)

| File | Change |
|---|---|
| `cmd/webhook/main.go` | Add `VfioDeviceConfig` to the type decoder switch. Validate `BackendPolicy` enum, `EnableAPIDevice` bool. |
| `api/.../validate.go` | Implement `VfioDeviceConfig.Validate()` — currently a no-op. Validate `Iommu.BackendPolicy` is one of `LegacyOnly` or `PreferIommuFD`. |

---

### PR 8: Sibling Mutual Exclusion and Re-Discovery

**Status:** Not started
**Target:** `develop`
**Size:** ~100-150 lines
**Depends on:** PR 1. Blocked by PCI config corruption bug (see below) — only matters for PF passthrough mode. Becomes urgent if/when PF passthrough works.

The AMD driver currently publishes compute (`amdgpu`) and VFIO (`amdgpu-vfio`) devices for the same PCI address independently. Nothing stops the scheduler from allocating both simultaneously.

NVIDIA's DRA driver handles this in two places:

1. **On prepare:** `perGPUAllocatable.RemoveSiblingDevices()` removes the compute GPU entry when its VFIO sibling is prepared (and vice versa). The ResourceSlice is re-published, so the scheduler can't allocate both.

2. **On unprepare:** `discoverSiblingAllocatables()` re-discovers the compute GPU (now back on the `nvidia` driver) and adds it back to the allocatable set. Re-publishes ResourceSlice.

**What to build:**

| File | Change |
|---|---|
| `cmd/gpu-kubeletplugin/allocatable.go` | Add `RemoveSiblingDevices(pciAddress)` — remove all devices sharing the same PCI address except the one being prepared |
| `cmd/gpu-kubeletplugin/state.go` `Prepare()` | After successful VFIO prepare, call `RemoveSiblingDevices()` and trigger ResourceSlice re-publication |
| `cmd/gpu-kubeletplugin/state.go` `Unprepare()` | After successful VFIO unconfigure, re-run discovery for that PCI address and add the compute device back to allocatables. Trigger re-publication. |
| `cmd/gpu-kubeletplugin/driver.go` | Expose a `republishResources()` method callable from state management |

**Note:** In the VF-only case (GIM creates VFs), the PF stays on `amdgpu` and VFs have different PCI addresses. Sibling exclusion doesn't apply between PF-compute and VF-VFIO — that's what counters handle (PR 5). Sibling exclusion only matters when the same PCI device could be either compute or VFIO (i.e., PF passthrough mode).

---

### PR 9: KubeVirt Example Manifests

**Status:** Not started
**Target:** `develop`
**Size:** ~100 lines of YAML
**Depends on:** PR 1 (basic examples), PR 4 (IOMMUFD example)

| File | Contents |
|---|---|
| `examples/vfio-claim.yaml` | ResourceClaim requesting `amdgpu-vfio` device |
| `examples/vfio-claim-iommufd.yaml` | ResourceClaim with `VfioDeviceConfig` + `IOMMUConfig` |
| `examples/kubevirt-vm-gpu-passthrough.yaml` | KubeVirt VirtualMachine referencing VFIO GPU claim |

---

### PR 10: GPU Operator Convergence

**Status:** Not started
**Target:** `ROCm/gpu-operator` `develop` (separate repo)
**Depends on:** PR 1 validated in production

| File | Change |
|---|---|
| `internal/controllers/workermgr/workermgr.go` | When DRA driver version supports VFIO (detected via ResourceSlice or Helm config), skip `vfio_bind.sh`/`vfio_unbind.sh` worker pod creation for `vf-passthrough`/`pf-passthrough` driver types |
| Helm values | Expose `PassthroughSupport` feature gate toggle for the DRA driver DaemonSet args |

---

## Mutual Exclusion: How Sibling Exclusion (PR 8) and Counters (PR 5) Interact

These solve different problems at different levels of the hardware hierarchy:

```
Physical GPU (PCI 0000:c1:00.0)
├── gpu-0 (compute, type=amdgpu)          ─┐
│                                           ├── Sibling exclusion (PR 8)
├── gpu-vfio-0 (PF passthrough, type=vfio) ─┘─┐
│                                              ├── Counter: consumes 8/8 vf-slots
│   GIM SR-IOV creates VFs:                    │
├── gpu-vfio-vf-0 (VF, type=vfio, isVF=true) ─┤── Counter: consumes 1/8 vf-slots
├── gpu-vfio-vf-1 (VF, type=vfio, isVF=true) ─┤── Counter: consumes 1/8 vf-slots
├── ...                                        │
└── gpu-vfio-vf-7 (VF, type=vfio, isVF=true) ─┘── Counter: consumes 1/8 vf-slots
```

**Sibling exclusion** prevents the same PCI device from being allocated as both a compute device (`gpu-0` on `amdgpu`) and a passthrough device (`gpu-vfio-0` on `vfio-pci`) at the same time. It works by removing one device type from the ResourceSlice when the other is prepared, and re-adding it on unprepare.

**KEP-4815 counters** prevent over-subscription of VFs from the same PF. A `SharedCounterSet` per PF has a `vf-slot` counter sized to `TotalVFs`. Each VF consumes 1 slot. If the PF itself is also allocatable as a VFIO device, it consumes all slots — making PF passthrough mutually exclusive with any VF allocation from that PF.

| Passthrough mode | Sibling exclusion needed? | Counters needed? |
|---|---|---|
| VF-only (GIM SR-IOV) — **the common AMD case** | No — PF stays on `amdgpu`, VFs are different PCI addresses | Yes — prevents VF over-subscription and PF+VF conflict |
| PF passthrough | Yes — prevents compute + VFIO on same PF | Yes — prevents PF + VF conflict |

For the current AMD implementation, GIM VFs are the primary path. PF passthrough is opt-in and currently broken on MI300X/MI355X (see below). **Counters (PR 5) are higher priority than sibling exclusion (PR 8).**

---

## KEP-4815 Counters and Multi-VF Partition Modes

### Current model: VF slot counters

The `SharedCounters` mechanism (PR 5) models VF slot allocation — one `CounterSet` per PF sized to `TotalVFs`. Each VF consumes 1 slot; PF passthrough consumes all slots. This works correctly for any GIM VF count (1, 2, or 8) because `TotalVFs` reflects whatever GIM was loaded with.

```
CounterSet "pf-0000-0c-00-0"  →  vf-slots: 8    (vf_num=8, CPX)
CounterSet "pf-0000-0c-00-0"  →  vf-slots: 2    (vf_num=2, DPX)
CounterSet "pf-0000-0c-00-0"  →  vf-slots: 1    (vf_num=1, SPX)
```

Each VF consumes 1 slot regardless of partition mode. The scheduler correctly limits allocations to the available VF count.

### Why VF-slot counters are sufficient today

GIM does not support mixed partition modes on the same PF. All VFs within a PF are identical — you can't have one DPX VF (4 XCCs) and four CPX VFs (1 XCC each) simultaneously. The `vf_num` is set at `modprobe gim` time and all VFs get equal resources. The `partitionProfile` attribute on each VF tells consumers what compute/memory each VF provides.

### Future opportunity: XCC-based counters

If AMD adds dynamic repartitioning in a future GIM release (resizing VFs without reloading GIM), XCC-based counters would enable heterogeneous allocation:

```
CounterSet "pf-0000-0c-00-0"  →  xcc-slots: 8
    CPX VF consumes 1 XCC     (can allocate up to 8)
    DPX VF consumes 4 XCCs    (can allocate up to 2)
    SPX VF consumes 8 XCCs    (can allocate 1, mutually exclusive)
    PF passthrough consumes 8  (mutually exclusive with all VFs)
```

The scheduler could then reason about compute capacity rather than VF slot counts — allocating one DPX VF (4 XCCs) would leave 4 XCCs for other allocations, not 7 "slots" that imply more capacity than exists.

**Decision:** Keep `vf-slots` for now. Switch to XCC-based counters if/when GIM supports dynamic repartitioning.

---

## Known Issue: PF Passthrough PCI Config Space Corruption (D-20)

**Status:** Workaround available. Observed on MI300X and MI355X.
**Repo:** AMD firmware / `amd/MxGPU-Virtualization`

When an AMD Instinct GPU PF is bound to `vfio-pci` and QEMU resets the device (FLR or bus reset), the PCI config space becomes permanently `0xFF`. The device cannot be recovered via PCI remove+rescan — only a full host reboot recovers it.

**Workaround:** Disable bus reset per-device via sysfs before binding to vfio-pci:
```bash
echo "" > /sys/bus/pci/devices/<bdf>/reset_method
```
This prevents QEMU from triggering a PCI bus reset. Tested successfully on MI355X — full PF passthrough cycle (amdgpu→vfio-pci→amdgpu) works with the workaround applied.

**Impact on this PR sequence:**
- VF passthrough via GIM SR-IOV is unaffected.
- PF passthrough works with the `reset_method` workaround and is gated behind `VFIOPassthrough` feature gate.
- GIM 9.1.0.K release notes confirm the same issue: "In configurations with 8 VFs per GPU, VF FLR may intermittently fail with 'SMU FW not responding' or 'SMU Timeout' errors."

**Resolution path:** Needs AMD firmware fix for proper FLR handling on MI300X/MI355X. The `reset_method` workaround is sufficient for testing and development.


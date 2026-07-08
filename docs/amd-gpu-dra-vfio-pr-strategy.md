# AMD GPU DRA Driver — VFIO/IOMMUFD PR Strategy

PR plan for landing VFIO passthrough and IOMMUFD support in `ROCm/k8s-gpu-dra-driver`. Based on review feedback from bhatnitish and yansun1996, existing branch work, and the NVIDIA DRA driver as reference implementation.

**Last updated:** 2026-07-08

---

## Current State

### Existing Branches (stacked, each includes all below it)

```
feature/vfio-kep4815-counters       ← KEP-4815 SharedCounters for PF/VF mutual exclusion
  └─ feature/vfio-kep5304-combined  ← KEP-5304 device metadata + VFIO claim metadata
       └─ feature/vfio-passthrough-v2  ← core VFIO: discovery, bind/unbind, CDI, tests (+1,588 lines)
            └─ main
```

### Open PRs

| PR | Title | Status | Reviewer Feedback |
|---|---|---|---|
| [#50](https://github.com/ROCm/k8s-gpu-dra-driver/pull/50) | VFIO passthrough for SR-IOV GPU VFs | Changes requested (yansun1996) — all 14 items addressed, tested on XE9680 + XE9785L | Both reviewers want **feature gate infra** before merge. bhatnitish: "having the entire feature under a gate is a good idea." Need to target `develop` branch. |
| [#48](https://github.com/ROCm/k8s-gpu-dra-driver/pull/48) | KEP-5304 device metadata | Changes requested (bhatnitish) — 3 items: target `develop`, add feature gate, run `make check` | bhatnitish reviewed 2026-07-07. Feature gate infra is the blocker. |

### Key Reviewer Requirements

1. **Target `develop` branch** — both PRs currently target `main` (bhatnitish, #48)
2. **Feature gate infrastructure** — driver has none today; both features need gates (bhatnitish + yansun1996)
3. **`make check` / `go fmt` clean** (bhatnitish, #48)

---

## PR Sequence

```
PR 0: Feature gate infra             ← UNBLOCKS EVERYTHING
  │
  ├── PR 1: VFIO passthrough (#50 rework)    gate: VFIOPassthrough (alpha, off)
  │
  └── PR 2: KEP-5304 metadata (#48 rework)   gate: DeviceMetadata (alpha, off)
        │
        └── PR 3: IOMMUFD support (new)      gate: VFIOPassthrough (same gate)
              │
              └── PR 4: KEP-4815 counters (new)  gate: VFIOPassthrough (same gate)
```

PR 1 and PR 2 are independent of each other — can merge in either order after PR 0.

---

### PR 0: Feature Gate Infrastructure

**Status:** Not started
**Target:** `develop`
**Size:** ~100-150 lines
**Blocks:** PR 1, PR 2

The driver's `--feature-gates` flag in `pkg/flags/logging.go` is private to `LoggingConfig`. This PR extracts it into shared infrastructure.

**What to build:**

| File | Change |
|---|---|
| `pkg/featuregates/featuregates.go` (new) | Shared feature gate registry. Register `VFIOPassthrough` (alpha, default false) and `DeviceMetadata` (alpha, default false). Use `k8s.io/component-base/featuregate` or a lightweight equivalent. |
| `cmd/gpu-kubeletplugin/main.go` | Register feature gates at startup, pass gate state to driver/state constructors via config struct or function args. |
| `pkg/flags/logging.go` | Refactor to use shared gate instance instead of private one. |

**Acceptance criteria:**
- `--feature-gates=VFIOPassthrough=true,DeviceMetadata=true` works from CLI
- Helm values can set feature gates via container args
- No functional changes — just plumbing

**Why separate:** Both bhatnitish and yansun1996 asked for gates. Shipping infra first keeps the VFIO and metadata PRs focused on their own logic and avoids re-review of gate mechanics inside a 1,500-line VFIO diff.

---

### PR 1: VFIO Passthrough (rework of #50)

**Status:** Code complete in `feature/vfio-passthrough-v2`. Needs rebase + gate wiring.
**Target:** `develop`
**Size:** ~1,500 lines (existing diff minus gate infra)
**Depends on:** PR 0
**Gate:** `VFIOPassthrough` (alpha, default false)
**Upstream issue:** [#49](https://github.com/ROCm/k8s-gpu-dra-driver/issues/49)
**Tested on:** XE9680 (MI300X), XE9785L (MI355X)

**What's already implemented:**

| Component | File | Done |
|---|---|---|
| PCI-level VFIO discovery (vendor `0x1002`) | `pkg/amdgpu/vfio.go` (351 lines) | Yes — GIM VF discovery, PF passthrough (opt-in), IOMMU group detection |
| VFIO bind/unbind manager | `cmd/gpu-kubeletplugin/vfio_manager.go` (263 lines) | Yes — `Configure()`/`Unconfigure()`, per-GPU locking, `driver_override` cleanup, CDI specs |
| `AmdGpuVFIOInfo` device type | `cmd/gpu-kubeletplugin/deviceinfo.go` | Yes |
| `AllocatableDevice` union extension | `cmd/gpu-kubeletplugin/allocatable.go` | Yes — `Vfio *AmdGpuVFIOInfo` field |
| Prepare/Unprepare dispatch | `cmd/gpu-kubeletplugin/state.go` | Yes — type-based routing to VFIO config path |
| `VfioDeviceConfig` API type | `api/.../api.go` | Yes — registered in scheme (empty struct, no IOMMUConfig yet) |
| Unit tests | `vfio_manager_test.go`, `vfio_test.go` | Yes — 577 lines, tmpdir-backed sysfs |
| Docs | `docs/installation.md` | Yes — prerequisites section |
| Helm | `values.yaml`, `kubeletplugin.yaml` | Yes — `enablePfPassthrough` toggle |

**Rework needed:**

1. Rebase onto `develop` branch
2. Replace `--enable-pf-passthrough` CLI flag with behavior under `VFIOPassthrough` gate
3. Guard all VFIO discovery/prepare/unprepare code behind `featuregates.Enabled(VFIOPassthrough)`
4. Run `make check` / `go fmt`
5. Squash fix commits for clean history

**Open question for yansun1996:** "let the DRA driver automatically detect PF vs VF" — the current code already does this (GIM VFs auto-discovered by scanning `/sys/bus/pci/drivers/gim/*/virtfn*`; PFs only discovered when opt-in flag is set, because PF passthrough corrupts MI300X/MI355X PCI config space on VFIO reset). Clarify whether yansun1996 wants PF discovery always-on or if the opt-in flag (now under the feature gate) is acceptable.

---

### PR 2: KEP-5304 Device Metadata (rework of #48)

**Status:** Code complete in `feat/kep5304-device-metadata-v2`. Needs rebase + gate wiring.
**Target:** `develop`
**Size:** ~200 lines
**Depends on:** PR 0
**Gate:** `DeviceMetadata` (alpha, default false)
**Upstream issue:** [#47](https://github.com/ROCm/k8s-gpu-dra-driver/issues/47)
**Tested on:** XE9680 (MI300X), XE9785L (MI355X)

**What's already implemented:**

- `kubeletplugin.EnableDeviceMetadata(true)` when gate is on
- `DeviceMetadata.Attributes` populated with `resource.kubernetes.io/pciBusID`, `productName`, `numaNode` in prepare path
- Works for both full GPUs and partitions

**Rework needed:**

1. Rebase onto `develop` branch
2. Gate behind `featuregates.Enabled(DeviceMetadata)` — only call `kubeletplugin.EnableDeviceMetadata(true)` and populate metadata when gate is on
3. Run `make check` / `go fmt`

**Note:** Independent of PR 1. Can merge before or after VFIO.

---

### PR 3: IOMMUFD Support (new — D-18)

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

### PR 4: KEP-4815 Counter Sets (new)

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

## Follow-Up Work (after core PRs land)

Items that should ship but don't need to block the core PR sequence. Each can be a small standalone PR against `develop`.

### Mutual Exclusion: How Sibling Exclusion and Counters Interact

Sibling exclusion (FU-1) and KEP-4815 counter sets (PR 4) solve different problems at different levels of the hardware hierarchy:

```
Physical GPU (PCI 0000:c1:00.0)
├── gpu-0 (compute, type=amdgpu)          ─┐
│                                           ├── Sibling exclusion (FU-1)
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

**Which do you need?**

| Passthrough mode | Sibling exclusion needed? | Counters needed? |
|---|---|---|
| VF-only (GIM SR-IOV) — **the common AMD case** | No — PF stays on `amdgpu`, VFs are different PCI addresses | Yes — prevents VF over-subscription and PF+VF conflict |
| PF passthrough | Yes — prevents compute + VFIO on same PF | Yes — prevents PF + VF conflict |

For the current AMD implementation, GIM VFs are the primary path. PF passthrough is opt-in and currently broken on MI300X/MI355X (see FU-6). **Counters (PR 4) are higher priority than sibling exclusion (FU-1).**

### FU-1: Sibling Mutual Exclusion and Re-Discovery

**Priority:** Low for now — only matters for PF passthrough mode, which is blocked by FU-6 (PCI config corruption). Becomes high priority if/when PF passthrough works.
**Ship with:** After FU-6 is resolved, or as defensive measure in PR 1
**Size:** ~100-150 lines

The AMD driver currently publishes compute (`amdgpu`) and VFIO (`amdgpu-vfio`) devices for the same PCI address independently. Nothing stops the scheduler from allocating both simultaneously.

NVIDIA's DRA driver handles this in two places:

1. **On prepare:** `perGPUAllocatable.RemoveSiblingDevices()` removes the compute GPU entry when its VFIO sibling is prepared (and vice versa). The ResourceSlice is re-published, so the scheduler can't allocate both.

2. **On unprepare:** `discoverSiblingAllocatables()` re-discovers the compute GPU (now back on the `nvidia` driver) and adds it back to the allocatable set. Re-publishes ResourceSlice.

**What to build in `k8s-gpu-dra-driver`:**

| File | Change |
|---|---|
| `cmd/gpu-kubeletplugin/allocatable.go` | Add `RemoveSiblingDevices(pciAddress)` — remove all devices sharing the same PCI address except the one being prepared |
| `cmd/gpu-kubeletplugin/state.go` `Prepare()` | After successful VFIO prepare, call `RemoveSiblingDevices()` and trigger ResourceSlice re-publication |
| `cmd/gpu-kubeletplugin/state.go` `Unprepare()` | After successful VFIO unconfigure, re-run discovery for that PCI address and add the compute device back to allocatables. Trigger re-publication. |
| `cmd/gpu-kubeletplugin/driver.go` | Expose a `republishResources()` method callable from state management |

**Note:** In the VF-only case (GIM creates VFs), the PF stays on `amdgpu` and VFs have different PCI addresses. Sibling exclusion doesn't apply between PF-compute and VF-VFIO — that's what counters handle. Sibling exclusion only matters when the same PCI device could be either compute or VFIO (i.e., PF passthrough mode).

### FU-2: VFIO DeviceClass Helm Template

**Priority:** Medium — users can create this manually, but shipping it in the chart is the expected UX.
**Ship with:** PR 1 or as follow-up
**Size:** ~20 lines

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

### FU-3: Webhook Validation for VfioDeviceConfig

**Priority:** Medium — prevents invalid configs from reaching the driver at prepare time.
**Ship with:** PR 3 (when `IOMMUConfig` fields land) or as follow-up
**Size:** ~50-100 lines

| File | Change |
|---|---|
| `cmd/webhook/main.go` | Add `VfioDeviceConfig` to the type decoder switch. Validate `BackendPolicy` enum, `EnableAPIDevice` bool. |
| `api/.../validate.go` | Implement `VfioDeviceConfig.Validate()` — currently a no-op. Validate `Iommu.BackendPolicy` is one of `LegacyOnly` or `PreferIommuFD`. |

### FU-4: KubeVirt Example Manifests

**Priority:** Low — documentation, not functionality.
**Ship as:** Follow-up after PR 1
**Size:** ~100 lines of YAML

| File | Contents |
|---|---|
| `examples/vfio-claim.yaml` | ResourceClaim requesting `amdgpu-vfio` device |
| `examples/vfio-claim-iommufd.yaml` | ResourceClaim with `VfioDeviceConfig` + `IOMMUConfig` (after PR 3) |
| `examples/kubevirt-vm-gpu-passthrough.yaml` | KubeVirt VirtualMachine referencing VFIO GPU claim |

### FU-5: GPU Operator Convergence

**Priority:** Low — current operator scripts still work, DRA is additive.
**Repo:** `ROCm/gpu-operator` (separate repo, separate PRs)
**Ship as:** After PR 1 is validated in production

| File | Change |
|---|---|
| `internal/controllers/workermgr/workermgr.go` | When DRA driver version supports VFIO (detected via ResourceSlice or Helm config), skip `vfio_bind.sh`/`vfio_unbind.sh` worker pod creation for `vf-passthrough`/`pf-passthrough` driver types |
| Helm values | Expose `PassthroughSupport` feature gate toggle for the DRA driver DaemonSet args |

### FU-6: PF Passthrough PCI Config Space Corruption (D-20)

**Priority:** High for PF passthrough viability — currently a hardware/firmware blocker.
**Status:** Not filed upstream. Observed on MI300X and MI355X.
**Repo:** AMD firmware / `amd/MxGPU-Virtualization`

When an AMD Instinct GPU PF is bound to `vfio-pci` and QEMU resets the device (FLR or bus reset), the PCI config space becomes permanently `0xFF`. The device cannot be recovered via PCI remove+rescan — only a full host reboot recovers it. This prevents PF passthrough entirely on MI300X and MI355X.

**Impact on this PR sequence:**
- VF passthrough via GIM SR-IOV is unaffected — VF config space reads `0xFFFF` for vendor:device (normal for GIM VFs, actual ID is in subsystem fields) but vfio-pci binds and operates correctly.
- PF passthrough is gated behind `--enable-pf-passthrough` (PR 1) precisely because of this bug. The flag documents it as an opt-in risk.
- FU-1 (sibling mutual exclusion) is lower priority because PF passthrough is blocked by this bug. Counters (PR 4) handle the VF case.

**Resolution path:** Needs AMD firmware investigation. May require a VFIO reset quirk in the kernel (`vfio-pci` reset hooks), or a firmware fix to handle FLR correctly on these ASICs. Not in scope for the DRA driver PRs — the driver correctly avoids the problem by defaulting to VF-only mode.

### FU-7: Standardized `numaNode` Attribute (D-8)

**Priority:** High for cross-driver NUMA alignment — required for `matchAttribute: resource.kubernetes.io/numaNode` to work across GPU, NIC, CPU, and memory drivers.
**Depends on:** KEP-6072 — K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) (numaNode helpers, awaiting `/lgtm` from ffromani)
**Branch:** `johnahull/k8s-gpu-dra-driver` `feature/standardized-topology-attrs`

The AMD driver publishes `numaNode` as a bare unqualified attribute. Other drivers publish vendor-specific names (`gpu.nvidia.com/numa`, `dra.cpu/numaNodeID`, `dra.net/numaNode`). For `matchAttribute` to align devices across drivers, all must use the standardized `resource.kubernetes.io/numaNode`.

**What's already implemented (in fork):**
- Publishes `resource.kubernetes.io/numaNode` (via `deviceattribute.GetNUMANodeAttributeByPCIBusID()`) alongside the bare `numaNode` for all device types (GPU, partition, VFIO)
- Publishes `resource.kubernetes.io/cpuSocketID` for socket-level topology
- VFIO devices get the same standardized attributes

**What's needed to upstream:**
1. K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) must merge (provides the `GetNUMANodeAttributeByPCIBusID` helper in `k8s.io/dynamic-resource-allocation/deviceattribute`)
2. Bump `k8s.io/dynamic-resource-allocation` dependency in `k8s-gpu-dra-driver` to pick up the helper
3. PR against `develop` — call the standardized helper for all device types in `GetDevice()`

**Can ship independently** of the VFIO PRs (affects all device types, not just VFIO). Should be a separate small PR once the K8s dependency is available.

**Sequencing with VFIO PRs:**
- The `feature/vfio-kep5304-combined` branch already includes the standardized numaNode for VFIO devices, but this depends on the K8s helper being available in the vendored dependency.
- If K8s #139929 merges before PR 1, include standardized numaNode in PR 1. If not, ship PR 1 with bare `numaNode` and add standardized form in FU-7 when the dependency is available.

---

## Immediate Actions

1. **Open PR 0** (feature gate infra) against `develop`. Small, uncontroversial, unblocks everything.
2. **Reply to bhatnitish on #48** — confirm option 1 (shared `--feature-gates`), coming as separate PR 0. Will rebase #48 onto `develop` with gate wiring after PR 0 merges.
3. **Reply to yansun1996 on #50** — confirm feature gate is coming via PR 0. Will rebase #50 onto `develop` with `VFIOPassthrough` gate. Clarify PF auto-detection question.
4. Once PR 0 merges, push reworked #50 and #48 (can be simultaneous since they're independent).

---

## What's NOT in This PR Sequence

These items are tracked elsewhere or are external dependencies:

| Item | Where |
|---|---|
| PF passthrough PCI config corruption (D-20) | FU-6 — AMD firmware issue, not a driver PR |
| GIM module build failures on kernel 6.19+/7.0+ (D-19) | `issues.md` D-19 — `amd/MxGPU-Virtualization` repo |
| KubeVirt VFIO capabilities (`CAP_SYS_RESOURCE`) | `issues.md` KV-7 — resolved by enabling `Root` feature gate globally |
| KubeVirt VM-scoped persistent ResourceClaims | KubeVirt PR [#17957](https://github.com/kubevirt/kubevirt/pull/17957) — independent of driver changes |

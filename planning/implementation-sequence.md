# Implementation Sequence

## Phase 1: Standardize Attributes — DONE

Standardized `resource.kubernetes.io/numaNode` and `cpuSocketID` published by all 4 drivers. Tested on NVIDIA A40 (R760xa) and AMD MI300X (XE9680).

| # | Item | Status |
|---|------|--------|
| 1 | `numaNode` standardization — all drivers publish `resource.kubernetes.io/numaNode` | **Done** — tested on NVIDIA A40 + AMD MI300X |
| 2 | `cpuSocketID` standardization — all drivers publish `resource.kubernetes.io/cpuSocketID` | **Done** — tested on NVIDIA A40 |
| 3 | `enforcement: preferred` — scheduler fallback hierarchy | **Done** (Phase 1b) |

Branches:
- `johnahull/dra-driver-nvidia-gpu` `feature/standardized-topology-attrs`
- `johnahull/dra-driver-cpu` `feature/standardized-topology-attrs`
- `johnahull/dra-driver-memory` `feature/standardized-topology-attrs`
- `johnahull/dra-driver-sriov` `feature/dra-topology-co-placement`

## Phase 1b: Scheduler enforcement:preferred — DONE

Patched K8s scheduler to support `enforcement: Preferred` on `matchAttribute`. Enables the distance hierarchy (pcieRoot → numaNode → cpuSocketID).

| # | Item | What | Where | Status |
|---|------|------|-------|--------|
| 3 | `enforcement: Preferred` | Add `Enforcement` field to `DeviceConstraint`, scheduler tries preferred constraints but relaxes if unsatisfiable | `johnahull/kubernetes` `feature/enforcement-preferred` | **Done** — tested on NVIDIA A40 |
| 3a | Patch all K8s components | All 5 binaries built from same branch to preserve the field end-to-end | `johnahull/kubernetes` `feature/enforcement-preferred` | **Done** |

Target: nvd-srv-31 (NVIDIA A40)

### Components patched

All built from `johnahull/kubernetes` branch `feature/enforcement-preferred` (3 commits):

| Component | Why |
|-----------|-----|
| **kube-apiserver** | Accept, validate, store `enforcement` field (types + protobuf + OpenAPI) |
| **kube-scheduler** | Experimental allocator with preferred constraint skip logic |
| **kube-controller-manager** | Copy template → claim preserving `enforcement` field |
| **kubelet** | Copy template → claim preserving `enforcement` field |
| **kubectl** | Send `enforcement` field without client-side stripping |

### Changes (3 commits)

1. API types: `Enforcement *ConstraintEnforcement` on `DeviceConstraint` (external + internal types, deepcopy, conversion)
2. Protobuf serialization (Marshal/Unmarshal/Size), OpenAPI schema, `DRAListTypeAttributes` feature gate default=true
3. `AllocatorFeatures()` passes `ListTypeAttributes` to select the experimental allocator; experimental allocator inline skip for preferred constraints

### Files modified

| File | Change |
|------|--------|
| `staging/src/k8s.io/api/resource/v1/types.go` | `Enforcement` field + `ConstraintEnforcement` type |
| `staging/src/k8s.io/api/resource/v1/zz_generated.deepcopy.go` | DeepCopy for `Enforcement` pointer |
| `staging/src/k8s.io/api/resource/v1/generated.pb.go` | Protobuf Marshal/Unmarshal/Size for field 4 |
| `pkg/apis/resource/types.go` | Internal `Enforcement` field + type |
| `pkg/apis/resource/zz_generated.deepcopy.go` | Internal DeepCopy |
| `pkg/apis/resource/v1/zz_generated.conversion.go` | Convert `Enforcement` between internal ↔ external |
| `pkg/generated/openapi/zz_generated.openapi.go` | OpenAPI schema for `enforcement` property |
| `pkg/features/kube_features.go` | `DRAListTypeAttributes` default=true |
| `pkg/scheduler/framework/plugins/dynamicresources/dynamicresources.go` | Pass `ListTypeAttributes` to `AllocatorFeatures()` |
| `staging/.../experimental/allocator_experimental.go` | `preferred` field + inline skip logic |

Test: `pcieRoot: Preferred` + `numaNode: Required` → GPU + CPU on NUMA 0 (pcieRoot relaxed because CPU doesn't publish pcieRoot)

## Phase 2: Topology Coordinator on NVIDIA

Deploy topology coordinator on nvd-srv-31 for partition abstraction alongside native matchAttribute.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 4 | Deploy coordinator | Build and deploy `test/all-fixes-combined` on nvd-srv-31 | `johnahull/k8s-dra-topology-coordinator` | Not started |
| 5 | ConfigMap rules for NVIDIA | Create topology rules for `gpu.nvidia.com` (attribute: `numa`) | — | Not started |
| 6 | Test partitions | Eighth/quarter pods via coordinator webhook | — | Not started |
| 7 | Compare native vs coordinator | Side-by-side: matchAttribute vs coordinator CEL selectors | — | Not started |

## Phase 3: KubeVirt on NVIDIA — DONE

DRA-native dual-NUMA VM with VFIO NIC passthrough on NVIDIA A40 system.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 8 | Deploy KubeVirt | KubeVirt v1.8.1 with patched virt-api, virt-controller, virt-launcher | `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1` | **Done** |
| 9 | SR-IOV VFIO passthrough | NIC VFs from both NUMA nodes passed through to VM via DRA | `johnahull/dra-driver-sriov` `feature/dra-topology-co-placement` | **Done** |
| 10 | Guest NUMA topology | 2 guest NUMA nodes with correct CPU/memory/device placement via pxb-pcie | `feature/dra-vfio-numa-passthrough-v1.8.1` | **Done** |
| 11 | DRA-native NUMA (no CPU manager) | Guest NUMA built from DRA CPU claims, no dedicatedCpuPlacement/hugepages/CPU manager | `feature/dra-vfio-numa-passthrough-v1.8.1` | **Done** |

### Key result

Dual-NUMA VM with 2 VFIO NICs (ConnectX-7 NUMA 0 + ConnectX-6 Dx NUMA 1) — guest sees 2 NUMA nodes with NICs correctly placed on their respective guest NUMA nodes. No kubelet CPU manager, no topology manager, no hugepages — fully DRA-native.

### Components patched for Phase 3

| Component | Changes |
|-----------|---------|
| **KubeVirt virt-api** | Relaxed validation: allow `guestMappingPassthrough` without `dedicatedCpuPlacement` or hugepages when DRA claims present |
| **KubeVirt virt-controller** | Pass non-hostDevice DRA claims (CPU, memory) to compute container's resource claims |
| **KubeVirt virt-launcher** | Build guest NUMA cells from DRA CPU claim allocation; apply pxb-pcie placement for DRA VFIO devices without requiring `PCINUMAAwareTopologyEnabled` |
| **SR-IOV DRA driver** | Default VfConfig when no OpaqueDeviceConfig; skip CNI for VFIO passthrough; KEP-5304 metadata (pciBusID); DRA v0.36.0 `DeviceMetadata` API |
| **DRA CPU driver** | Added `/var/run/cdi` hostPath volume mount for CDI spec visibility |

### Guest verification

```
$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3
node 0 size: 3961 MB
node 1 cpus: 4 5 6 7
node 1 size: 3972 MB
node distances:
node   0   1
  0:  10  20
  1:  20  10

$ cat /sys/class/net/*/device/numa_node
enp253s0 NUMA=0   # ConnectX-7 VF from host NUMA 0
enp255s0 NUMA=1   # ConnectX-6 Dx VF from host NUMA 1
```

## Phase 4: Driver Patches (AMD)

Existing AMD-specific patches from XE9680 testing.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 12 | AMD GPU bug fixes | Multi-driver claim filter + version fallback | `johnahull/k8s-gpu-dra-driver` `fix/multi-driver-claim-filter` | Patched |
| 13 | KEP-5304 for AMD GPU | pciBusID + numaNode in PrepareResult metadata | `feat/kep5304-device-metadata` | Patched |
| 14 | AMD GPU VFIO support | Discovery + config + CDI + bind/unbind | `feature/vfio-passthrough` | Patched |
| 15 | GIM kernel compat | `vm_flags_set()` for kernel 6.3+ | `johnahull/MxGPU-Virtualization` `fix/kernel-6.17-compat` | Patched |

## Phase 5: Upstream Proposals

| # | Item | Doc | Status |
|---|------|-----|--------|
| 16 | numaNode + cpuSocketID + enforcement:preferred proposal | `docs/upstream-proposals/proposal-topology-distance-hierarchy.md` | Ready to post |
| 17 | KEP-5304 auto-populate issue | `docs/upstream-proposals/kep5304-auto-populate-metadata.md` | Not filed |
| 18 | KubeVirt multi-device DRA issue | `docs/upstream-proposals/kubevirt-multi-device-dra-requests.md` | Not filed |

## Test Evidence

| Platform | Hardware | Tests Passed | Key Result |
|----------|----------|-------------|------------|
| Dell XE9680 | 8x AMD MI300X + ConnectX-6 | Eighth, quarter pods + KubeVirt VMs (SNC on/off) | Coordinator + per-driver CEL + distance fallback |
| Dell R760xa | 2x NVIDIA A40 + ConnectX-7 + ConnectX-6 Dx | 4-driver matchAttribute + enforcement:preferred + KubeVirt dual-NUMA VM | **Native cross-driver alignment + distance hierarchy + DRA-native guest NUMA topology** |

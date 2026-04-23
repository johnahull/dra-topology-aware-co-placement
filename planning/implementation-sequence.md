# Implementation Sequence

## Phase 1: Standardize Attributes — DONE

Standardized `resource.kubernetes.io/numaNode` and `cpuSocketID` published by all 4 drivers. Tested on NVIDIA A40 (R760xa) and AMD MI300X (XE9680).

| # | Item | Status |
|---|------|--------|
| 1 | `numaNode` standardization — all drivers publish `resource.kubernetes.io/numaNode` | **Done** — tested on NVIDIA A40 + AMD MI300X |
| 2 | `cpuSocketID` standardization — all drivers publish `resource.kubernetes.io/cpuSocketID` | **Done** — tested on NVIDIA A40 |
| 3 | `enforcement: preferred` — scheduler fallback hierarchy | Next (Phase 1b) |

Branches:
- `johnahull/dra-driver-nvidia-gpu` `feature/standardized-topology-attrs`
- `johnahull/dra-driver-cpu` `feature/standardized-topology-attrs`
- `johnahull/dra-driver-memory` `feature/standardized-topology-attrs`
- `johnahull/dra-driver-sriov` `feature/dra-topology-co-placement`

## Phase 1b: Scheduler enforcement:preferred — NEXT

Patch K8s scheduler to support `enforcement: preferred` on `matchAttribute`. Enables the distance hierarchy (pcieRoot → numaNode → cpuSocketID).

| # | Item | What | Where | Status |
|---|------|------|-------|--------|
| 3 | `enforcement: preferred` | Add `enforcement` field to `DeviceConstraint`, scheduler tries preferred constraints but relaxes if unsatisfiable | Fork `kubernetes/kubernetes` at v1.36.0 | Not started |

Target: nvd-srv-31 (NVIDIA A40)

## Phase 2: Topology Coordinator on NVIDIA

Deploy topology coordinator on nvd-srv-31 for partition abstraction alongside native matchAttribute.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 4 | Deploy coordinator | Build and deploy `test/all-fixes-combined` on nvd-srv-31 | `johnahull/k8s-dra-topology-coordinator` | Not started |
| 5 | ConfigMap rules for NVIDIA | Create topology rules for `gpu.nvidia.com` (attribute: `numa`) | — | Not started |
| 6 | Test partitions | Eighth/quarter pods via coordinator webhook | — | Not started |
| 7 | Compare native vs coordinator | Side-by-side: matchAttribute vs coordinator CEL selectors | — | Not started |

## Phase 3: KubeVirt on NVIDIA

Test KubeVirt VFIO passthrough with guest NUMA topology on NVIDIA A40.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 8 | Deploy KubeVirt | Install KubeVirt v1.8.1 with patched controller + launcher | `johnahull/kubevirt` branches | Not started |
| 9 | NVIDIA VFIO passthrough | Bind A40 to vfio-pci, create VM with GPU passthrough | — | Not started |
| 10 | Guest NUMA topology | Verify pxb-pcie placement from standardized numaNode in KEP-5304 metadata | `feature/dra-numa-guest-topology` | Not started |
| 11 | Dual-NUMA VM | VM with devices from both NUMA nodes, device-only cells | — | Not started |

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
| Dell R760xa | 2x NVIDIA A40 + ConnectX-7 | 4-driver matchAttribute numaNode + cpuSocketID | **Native cross-driver alignment, no middleware** |

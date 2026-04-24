# NVIDIA A40 Session — 2026-04-23/24

**Hardware:** Dell R760xa (nvd-srv-31) — 2x Intel Xeon Gold 6548Y+, 2x NVIDIA A40, ConnectX-7 + ConnectX-6 Dx + BlueField-3
**OS:** Fedora 43, kernel 6.19.13
**K8s:** Custom v1.37.0-alpha.0 (enforcement:preferred branch)
**KubeVirt:** v1.8.1 with DRA-native NUMA patches

## Summary

This session proved four major capabilities:

1. **enforcement:preferred** — scheduler falls back gracefully when tight constraints can't be satisfied
2. **DRA-native KubeVirt NUMA** — guest NUMA topology built from DRA CPU claims, no CPU manager needed
3. **SR-IOV NIC VFIO passthrough** — DRA claims allocate NICs from specific NUMA nodes and bind to vfio-pci
4. **NVIDIA GPU VFIO passthrough** — DRA claims allocate VFIO GPUs via the NVIDIA DRA driver's PassthroughSupport feature

## Phase 1b: enforcement:preferred

### What we built

Added `enforcement: Preferred` to the K8s `DeviceConstraint` API. When a preferred `matchAttribute` constraint can't be satisfied (e.g., a device lacks the attribute), the scheduler skips it instead of rejecting the allocation.

### Changes (5 K8s components, 10 files)

All from `johnahull/kubernetes` branch `feature/enforcement-preferred`:

| Component | Why |
|-----------|-----|
| kube-apiserver | Accept, validate, store the `enforcement` field (types + protobuf + OpenAPI) |
| kube-scheduler | Experimental allocator with preferred constraint skip logic |
| kube-controller-manager | Copy template → claim preserving the field |
| kubelet | Copy template → claim preserving the field |
| kubectl | Send field without client-side stripping |

### Files modified

| File | Change |
|------|--------|
| `staging/src/k8s.io/api/resource/v1/types.go` | `Enforcement *ConstraintEnforcement` field + type constants |
| `staging/src/k8s.io/api/resource/v1/zz_generated.deepcopy.go` | DeepCopy for pointer field |
| `staging/src/k8s.io/api/resource/v1/generated.pb.go` | Protobuf Marshal/Unmarshal/Size for field 4 |
| `pkg/apis/resource/types.go` | Internal API types |
| `pkg/apis/resource/zz_generated.deepcopy.go` | Internal DeepCopy |
| `pkg/apis/resource/v1/zz_generated.conversion.go` | Internal ↔ external conversion |
| `pkg/generated/openapi/zz_generated.openapi.go` | OpenAPI schema (prevents field pruning) |
| `pkg/features/kube_features.go` | `DRAListTypeAttributes` default=true |
| `pkg/scheduler/framework/plugins/dynamicresources/dynamicresources.go` | Pass `ListTypeAttributes` to select experimental allocator |
| `staging/.../experimental/allocator_experimental.go` | `preferred` field + inline skip on mismatch |

### Key learnings

- Adding a field to a K8s API requires changes in 6 layers: external types, internal types, conversion, deepcopy, protobuf, and OpenAPI
- Without protobuf serialization, the field is lost on etcd roundtrip
- Without OpenAPI schema, the apiserver prunes it as unknown
- kubectl v1.36 strips unknown fields client-side — need patched kubectl
- The kubelet also copies template → claim, so it needs the field too
- The experimental allocator is selected by feature gate → `AllocatorFeatures()` mapping

### Test result

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, cpu]
  enforcement: Preferred    # CPU has no pcieRoot → relaxed
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]      # Both have numaNode → satisfied
```

GPU `gpu-0` + CPU `cpudevnuma000` allocated on NUMA 0. The pcieRoot constraint was relaxed because CPU doesn't publish pcieRoot.

---

## Phase 3: KubeVirt on NVIDIA

### What we built

A dual-NUMA KubeVirt VM with GPU + NIC VFIO passthrough, where guest NUMA topology is built entirely from DRA claims — no kubelet CPU manager, no topology manager, no hugepages.

### Components deployed

| Component | Image/Binary | Changes |
|-----------|-------------|---------|
| KubeVirt v1.8.1 operator | Stock `quay.io/kubevirt` | No changes |
| virt-api | Custom from `feature/dra-vfio-numa-passthrough-v1.8.1` | Relaxed validation: `guestMappingPassthrough` without `dedicatedCpuPlacement` or hugepages when DRA claims present |
| virt-controller | Custom from same branch | Pass non-hostDevice DRA claims (CPU, memory) to compute container |
| virt-launcher | Custom, built in CentOS Stream 9 container | Build guest NUMA cells from DRA CPU claim names; apply pxb-pcie placement for VFIO devices |
| SR-IOV DRA driver | Custom from `feature/dra-topology-co-placement` | 4 fixes (see below) |
| NVIDIA DRA driver | Custom from `feature/standardized-topology-attrs` | DeviceMetadata version gate + PassthroughSupport enabled |
| DRA CPU driver | Stock + CDI volume mount fix | Added `/var/run/cdi` hostPath for CDI spec visibility |

### SR-IOV DRA driver fixes

| Commit | Fix |
|--------|-----|
| Default VfConfig | Claims without `OpaqueDeviceConfig` use default config instead of failing |
| Skip CNI for VFIO | NRI `RunPodSandbox` skips `AttachNetwork` for devices without NAD config |
| KEP-5304 metadata | `DeviceMetadata` with `pciBusID` attribute in `PrepareResult` |
| MetadataVersions | Register `v1alpha1` metadata API version at startup |

### KubeVirt DRA-native NUMA changes

| File | Change |
|------|--------|
| `vmi-create-admitter.go` | Allow `guestMappingPassthrough` without `dedicatedCpuPlacement`/hugepages when `resourceClaims` present |
| `renderresources.go` | `WithExtraResourceClaims()` — pass CPU/memory DRA claims to compute container |
| `template.go` | Add predicate to apply extra claims for all VMIs with `resourceClaims` |
| `converter.go` | `buildDRANUMACells()` — create guest NUMA cells from DRA CPU claim allocations; `NUMATune` with strict memory binding; apply pxb-pcie placement unconditionally when DRA overrides exist |

### NVIDIA GPU VFIO passthrough

The NVIDIA DRA driver already had full VFIO support behind the `PassthroughSupport` feature gate. Changes needed:

1. Enable `PassthroughSupport=true` in the kubelet plugin args
2. Enable `DeviceMetadata=true` (requires version ≥ v26.4 — we lowered to v25.12)
3. Create `gpu-vfio.nvidia.com` DeviceClass to filter VFIO devices (`type == "vfio"`)
4. Build with correct ldflags (`-X internal/info.version=v25.12.0`) to avoid version panic

### Device topology

| NUMA | Devices |
|------|---------|
| 0 | A40 GPU `4a:00.0` (vfio-pci), ConnectX-7 VFs (vfio-pci), CPU `cpudevnuma000`, Memory |
| 1 | ConnectX-6 Dx VFs (vfio-pci), CPU `cpudevnuma001`, Memory |

### VM specification

```yaml
# 5 DRA claims — no dedicatedCpuPlacement, no hugepages, no CPU manager
resourceClaims:
- name: gpu0       # NVIDIA A40 VFIO from NUMA 0
  resourceClaimName: vm-gpu-numa0
- name: nic0       # ConnectX-7 VF from NUMA 0 (vfio-pci)
  resourceClaimName: vm-nic-numa0
- name: nic1       # ConnectX-6 Dx VF from NUMA 1 (vfio-pci)
  resourceClaimName: vm-nic-numa1
- name: cpu0       # DRA CPU from NUMA 0
  resourceClaimName: vm-cpu-numa0
- name: cpu1       # DRA CPU from NUMA 1
  resourceClaimName: vm-cpu-numa1
```

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

$ lspci | grep -i nvidia
fe:00.0 3D controller: NVIDIA Corporation GA102GL [A40] (rev a1)

$ for dev in /sys/class/net/*/device/numa_node; do
    echo $(basename $(dirname $(dirname $dev))): NUMA=$(cat $dev)
  done
enp252s0: NUMA=1   # ConnectX-6 Dx VF from host NUMA 1
enp255s0: NUMA=0   # ConnectX-7 VF from host NUMA 0
```

### What this proves

- Guest sees 2 NUMA nodes with correct CPU/memory split
- NVIDIA A40 GPU visible inside guest via DRA VFIO passthrough
- VFIO NICs placed on correct guest NUMA nodes via pxb-pcie expander buses
- No kubelet CPU manager, no topology manager, no hugepages required
- DRA CPU driver handles CPU allocation per NUMA via NRI
- DRA SR-IOV driver handles NIC VFIO passthrough with KEP-5304 metadata
- NVIDIA DRA driver handles GPU VFIO passthrough with DeviceMetadata
- KubeVirt builds guest NUMA topology entirely from DRA claim allocations
- **First DRA-native guest NUMA topology for KubeVirt VMs**

---

## All repos and branches

| Repo | Branch | Changes this session |
|------|--------|---------------------|
| `johnahull/kubernetes` | `feature/enforcement-preferred` | enforcement:preferred API + allocator (3 commits) |
| `johnahull/kubevirt` | `feature/dra-vfio-numa-passthrough-v1.8.1` | Rebase to v1.8.1 + DRA-native NUMA (6 commits) |
| `johnahull/dra-driver-sriov` | `feature/dra-topology-co-placement` | VFIO passthrough fixes + KEP-5304 metadata (4 commits) |
| `johnahull/dra-driver-nvidia-gpu` | `feature/standardized-topology-attrs` | DeviceMetadata version gate (1 commit) |
| `johnahull/dra-topology-aware-co-placement` | `main` | Docs, demo script, numa-topology.sh fix |

## Remaining work

| Item | Status |
|------|--------|
| Topology coordinator on NVIDIA | Not started |
| Upstream proposal posting | Ready — `docs/upstream-proposals/proposal-topology-distance-hierarchy.md` |
| NVIDIA DRA driver `WaitForGPUFree` fix | Needed for auto-binding GPUs not already on vfio-pci |
| DRA CPU driver KEP-5304 metadata | Needed for proper NUMA detection (currently using claim name pattern) |
| KubeVirt DRA memory claims | Not implemented — memory is not NUMA-bound in the guest |

# Issues Tracker

Running list of issues to fix across all repos. Updated as PRs are opened/merged.

## Open

### Kubelet

| # | Issue | Repo | Branch/PR | Notes |
|---|-------|------|-----------|-------|
| K-1 | DRA topology hints: kubelet doesn't provide NUMA hints for DRA devices | `kubernetes/kubernetes` | `johnahull/kubernetes` `feature/enforcement-preferred` `77a449e` | New `topology_hints.go` — DRA Manager implements HintProvider. Requires `spec.nodeName` field selector for Node Authorizer. |
| K-2 | CPU manager reconciler never corrects cgroup cpuset mismatches | `kubernetes/kubernetes` | `johnahull/kubernetes` `feature/enforcement-preferred` `77a449e` | `AddContainer` set `lastUpdateState` without writing cgroup. Reconciler thought cpuset was already applied. |
| K-3 | CPU manager cpuset not applied before container starts | `kubernetes/kubernetes` | `johnahull/kubernetes` `feature/enforcement-preferred` `77a449e` | containerd doesn't apply `CpusetCpus` from CRI config during creation. Added `updateContainerCPUSet` in `AddContainer`. |

### KubeVirt

| # | Issue | Repo | Branch/PR | Notes |
|---|-------|------|-----------|-------|
| KV-1 | `copyResourceClaims` deduplicates by Name only, drops second request from same claim | `kubevirt/kubevirt` | `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1` | Fixed: dedup by `{Name, Request}` |
| KV-2 | `WithExtraResourceClaims` skips claims already referenced by GPU/hostDevice | `kubevirt/kubevirt` | `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1` `595bdfb` | Fixed: adds all VMI claims without filter |
| KV-3 | `WithGPUsDRA`/`WithHostDevicesDRA` cause duplicate claim name API errors | `kubevirt/kubevirt` | `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1` `595bdfb` | Fixed: simplified to no-ops, all claims via `WithExtraResourceClaims` |
| KV-4 | `guestMappingPassthrough` fragile — reads cpuset once at startup with no retry | `kubevirt/kubevirt` | — | Workaround: kubelet fix K-3. virt-launcher should validate cpuset/mems consistency or retry. |
| KV-5 | VEP 115 reads device NUMA from sysfs only, not from DRA KEP-5304 metadata | `kubevirt/kubevirt` | `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1` | Patched locally. Needs upstream proposal. |
| KV-6 | ACPI not auto-enabled when guest NUMA topology is used | `kubevirt/kubevirt` | — | Not yet fixed. |

### DRA Drivers

| # | Issue | Repo | Branch/PR | Notes |
|---|-------|------|-----------|-------|
| D-1 | SR-IOV DRA driver: no KEP-5304 `pciBusID` metadata | `k8snetworkplumbingwg/dra-driver-sriov` | — | KubeVirt can't create VFIO passthrough for NIC VFs. Workaround: use dranet. |
| D-2 | NVIDIA GPU DRA driver: `numaNode` not published for standard (non-VFIO) GPU devices | `NVIDIA/k8s-dra-driver-gpu` | — | Only VFIO type gets `resource.kubernetes.io/numaNode`. Standard GPUs missing it. |
| D-3 | NVIDIA GPU DRA driver: KEP-5304 opt-in not yet available | `NVIDIA/k8s-dra-driver-gpu` | — | Issue #916, targeting v26.4.0. |
| D-4 | dranet: VFIO support not upstream | `kubernetes-sigs/dranet` | `johnahull/dranet` `feature/standardized-topology-attrs` | Full VFIO bind/unbind + CDI. Needs upstream PR. |
| D-5 | dranet: standardized topology attrs not upstream | `kubernetes-sigs/dranet` | `johnahull/dranet` `feature/standardized-topology-attrs` | `resource.kubernetes.io/numaNode`, `cpuSocketID`, `pciBusID`, `pcieRoot`. |

### Kubernetes Upstream

| # | Issue | Repo | Branch/PR | Notes |
|---|-------|------|-----------|-------|
| U-1 | `enforcement: Preferred` not in upstream API | `kubernetes/kubernetes` | `johnahull/kubernetes` `feature/enforcement-preferred` | 3 commits: API field, protobuf/OpenAPI, allocator skip. Needs KEP. |
| U-2 | Standardized `resource.kubernetes.io/numaNode` and `cpuSocketID` not agreed | `kubernetes/kubernetes` | — | [Proposal](docs/upstream-proposals/standardize-numanode-and-socket.md). Discussed in SIG-Node. |
| U-3 | `deviceattribute` library: `GetPCIeRootAttributeMapFromCPUId` helper | `kubernetes/kubernetes` | [#138297](https://github.com/kubernetes/kubernetes/pull/138297) | WIP PR. |

## Closed

_None yet._

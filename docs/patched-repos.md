# Patched Repos — DRA Topology-Aware Co-Placement

All forks live under [github.com/johnahull](https://github.com/johnahull).

## Repos with Branches

| Upstream Repo | Fork | Branch | Description |
|---------------|------|--------|-------------|
| [kubevirt/kubevirt](https://github.com/kubevirt/kubevirt) | [johnahull/kubevirt](https://github.com/johnahull/kubevirt) | `feature/dra-numa-guest-topology` | DRA → VEP 115 bridge: KEP-5304 metadata → guest NUMA cells + pxb-pcie placement — 5 files |
| | | `feature/dra-vfio-numa-passthrough` | Full stack: DRA NUMA bridge + VFIO passthrough (locked memory, capabilities, root mode) — 12 files |
| | | `feature/dra-vfio-numa-passthrough-v1.8.1` | **v1.8.1 rebase** + DRA-native NUMA (no CPU manager): relaxed validation, DRA CPU claims → guest NUMA cells, pxb-pcie placement |
| [k8s-sigs/dranet](https://github.com/kubernetes-sigs/dranet) | [johnahull/dranet](https://github.com/johnahull/dranet) | `feature/standardized-topology-attrs` | Standardized topology attrs + VFIO passthrough for NIC VFs — replaces SR-IOV DRA driver on R760xa |
| [k8snetworkplumbingwg/dra-driver-sriov](https://github.com/k8snetworkplumbingwg/dra-driver-sriov) | [johnahull/dra-driver-sriov](https://github.com/johnahull/dra-driver-sriov) | `feature/dra-topology-co-placement` | KEP-5304 metadata + VFIO passthrough (superseded by dranet on R760xa) |
| [ffromani/dra-driver-memory](https://github.com/ffromani/dra-driver-memory) | [johnahull/dra-driver-memory](https://github.com/johnahull/dra-driver-memory) | `feature/dra-topology-co-placement` | Dockerfile + preflight + dependency updates |
| — (new project) | [johnahull/dra-driver-nvme](https://github.com/johnahull/dra-driver-nvme) | `main` | NVMe DRA driver: sysfs discovery, block + VFIO modes, standardized topology attrs, KEP-5304 metadata |
| [amd/MxGPU-Virtualization](https://github.com/amd/MxGPU-Virtualization) | [johnahull/MxGPU-Virtualization](https://github.com/johnahull/MxGPU-Virtualization) | `fix/kernel-6.17-compat` | `vm_flags_set()` for kernel 6.3+ |
| [fabiendupont/k8s-dra-topology-coordinator](https://github.com/fabiendupont/k8s-dra-topology-coordinator) | [johnahull/k8s-dra-topology-coordinator](https://github.com/johnahull/k8s-dra-topology-coordinator) | `fix/distance-based-fallback` | pcieRoot → numaNode fallback with CouplingLevel |
| | | `fix/numanode-attribute-namespace` | Per-driver NUMA attribute namespacing |
| | | `fix/pcieroot-constraint-non-pci-drivers` | Skip non-PCI drivers in pcieRoot constraints |
| | | `fix/per-driver-cel-selectors` | Per-driver CEL selectors replacing cross-driver matchAttribute |
| | | `fix/webhook-forward-cel-selectors` | Forward user CEL selectors through webhook |
| | | `test/all-fixes-combined` | Combined branch with all fixes |
| [ROCm/k8s-gpu-dra-driver](https://github.com/ROCm/k8s-gpu-dra-driver) | [johnahull/k8s-gpu-dra-driver](https://github.com/johnahull/k8s-gpu-dra-driver) | `fix/multi-driver-claim-filter` | Multi-driver claim filter + driver version fallback — 1 commit |
| | | `feat/kep5304-device-metadata` | KEP-5304 metadata (pciBusID + numaNode in PrepareResult) — 2 commits (includes bug fixes) |
| | | `feature/vfio-passthrough` | Full stack: bug fixes + KEP-5304 + VFIO discovery + VFIO config/CDI — 4 commits |
| | (patches also on upstream remote) | `develop` | GPU partition fixes, MI210 support |
| | | `feature-auto-partition` | Automatic partition discovery |

## K8s enforcement:preferred + DRA topology hints (full stack)

| Upstream Repo | Fork | Branch | Description |
|---------------|------|--------|-------------|
| [kubernetes/kubernetes](https://github.com/kubernetes/kubernetes) | [johnahull/kubernetes](https://github.com/johnahull/kubernetes) | `feature/enforcement-preferred` | `enforcement:Preferred` for `DeviceConstraint` (3 commits) + DRA topology hints + CPU manager bug fixes (1 commit) |

Binaries built from this branch: **kube-apiserver**, **kube-scheduler**, **kube-controller-manager**, **kubelet**, **kubectl**. All 5 are required to preserve the `enforcement` field end-to-end (API types, protobuf, OpenAPI, template→claim copy, client-side).

The kubelet commit (`77a449e2573`) adds:
- `topology_hints.go` — DRA Manager implements `topologymanager.HintProvider`, reads `resource.kubernetes.io/numaNode` from ResourceSlice
- Node Authorizer fix — `ResourceSlices().List()` requires `spec.nodeName` field selector
- CPU manager `AddContainer` fix — calls `updateContainerCPUSet` immediately (fixes cpuset race with virt-launcher)
- CPU manager reconciler fix — don't pre-populate `lastUpdateState` without writing cgroup

## Standardized Topology Attributes (proposal validation)

| Upstream Repo | Fork | Branch | Description |
|---------------|------|--------|-------------|
| [NVIDIA/k8s-dra-driver-gpu](https://github.com/NVIDIA/k8s-dra-driver-gpu) | [johnahull/dra-driver-nvidia-gpu](https://github.com/johnahull/dra-driver-nvidia-gpu) | `feature/standardized-topology-attrs` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` to GPU, MIG, VFIO |
| [kubernetes-sigs/dra-driver-cpu](https://github.com/kubernetes-sigs/dra-driver-cpu) | [johnahull/dra-driver-cpu](https://github.com/johnahull/dra-driver-cpu) | `feature/standardized-topology-attrs` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` alongside `dra.cpu/numaNodeID` |
| [ffromani/dra-driver-memory](https://github.com/ffromani/dra-driver-memory) | [johnahull/dra-driver-memory](https://github.com/johnahull/dra-driver-memory) | `feature/standardized-topology-attrs` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` + NRI UpdatePodSandbox fix |
| [k8s-sigs/dranet](https://github.com/kubernetes-sigs/dranet) | [johnahull/dranet](https://github.com/johnahull/dranet) | `feature/standardized-topology-attrs` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` + `pciBusID` + `pcieRoot` + VFIO support |
| [k8snetworkplumbingwg/dra-driver-sriov](https://github.com/k8snetworkplumbingwg/dra-driver-sriov) | [johnahull/dra-driver-sriov](https://github.com/johnahull/dra-driver-sriov) | `feature/dra-topology-co-placement` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` + NRI plugin index fix |

## Platforms

### Dell PowerEdge R760xa (NVIDIA) — active

- **IP:** 10.6.135.10
- **Hardware:** 2x NVIDIA A40 GPUs, ConnectX-7 + ConnectX-6 Dx NICs (SR-IOV VFs), 2-socket Intel Xeon Gold 6548Y+, 128 threads, 256 GB
- **OS:** Fedora 43, kernel 6.19.13
- **K8s:** Custom v1.37.0-alpha.0 (enforcement:preferred + DRA topology hints)
- **Kubelet:** Custom build with DRA topology hints + CPU manager fixes
- **NIC driver:** dranet (`feature/standardized-topology-attrs`)
- **Status:** All tests passing. VM with `guestMappingPassthrough` + GPU VFIO + DRA CPU pinning working.

### Dell XE8640 (NVIDIA) — down

- **IP:** 10.6.62.51
- **Hardware:** 4x NVIDIA H100 SXM5, ConnectX-7 + E810 NICs, 2-socket Intel
- **Status:** Filesystem issues, needs repair. Was running full 5-driver stack (GPU + NIC + NVMe + CPU + memory).

### Dell XE9680 (AMD) — original test system

- **Hardware:** 8x AMD MI300X GPUs, ConnectX-6 NICs, 2-socket Intel, 128 CPUs
- **OS:** Fedora 43, kernel 6.17/6.19
- **K8s:** 1.36.0-rc.0
- **Status:** Original topology coordinator and SNC testing. Not actively maintained.

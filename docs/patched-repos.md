# Patched Repos — DRA Topology-Aware Co-Placement

All forks live under [github.com/johnahull](https://github.com/johnahull).

## Repos with Branches

| Upstream Repo | Fork | Branch | Description |
|---------------|------|--------|-------------|
| [kubevirt/kubevirt](https://github.com/kubevirt/kubevirt) | [johnahull/kubevirt](https://github.com/johnahull/kubevirt) | `feature/dra-numa-guest-topology` | DRA → VEP 115 bridge: KEP-5304 metadata → guest NUMA cells + pxb-pcie placement — 5 files |
| | | `feature/dra-vfio-numa-passthrough` | Full stack: DRA NUMA bridge + VFIO passthrough (locked memory, capabilities, root mode) — 12 files |
| [k8snetworkplumbingwg/dra-driver-sriov](https://github.com/k8snetworkplumbingwg/dra-driver-sriov) | [johnahull/dra-driver-sriov](https://github.com/johnahull/dra-driver-sriov) | `feature/dra-topology-co-placement` | KEP-5304 metadata, DRA hook/driver fixes |
| [ffromani/dra-driver-memory](https://github.com/ffromani/dra-driver-memory) | [johnahull/dra-driver-memory](https://github.com/johnahull/dra-driver-memory) | `feature/dra-topology-co-placement` | Dockerfile + preflight + dependency updates |
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

## Scheduler enforcement:preferred

| Upstream Repo | Fork | Branch | Description |
|---------------|------|--------|-------------|
| [kubernetes/kubernetes](https://github.com/kubernetes/kubernetes) | [johnahull/kubernetes](https://github.com/johnahull/kubernetes) | `feature/enforcement-preferred` | Add `Enforcement` field to `DeviceConstraint`, experimental allocator skips preferred constraints on mismatch — 3 commits |

## Standardized Topology Attributes (proposal validation)

| Upstream Repo | Fork | Branch | Description |
|---------------|------|--------|-------------|
| [NVIDIA/k8s-dra-driver-gpu](https://github.com/NVIDIA/k8s-dra-driver-gpu) | [johnahull/dra-driver-nvidia-gpu](https://github.com/johnahull/dra-driver-nvidia-gpu) | `feature/standardized-topology-attrs` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` to GPU, MIG, VFIO |
| [kubernetes-sigs/dra-driver-cpu](https://github.com/kubernetes-sigs/dra-driver-cpu) | [johnahull/dra-driver-cpu](https://github.com/johnahull/dra-driver-cpu) | `feature/standardized-topology-attrs` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` alongside `dra.cpu/numaNodeID` |
| [ffromani/dra-driver-memory](https://github.com/ffromani/dra-driver-memory) | [johnahull/dra-driver-memory](https://github.com/johnahull/dra-driver-memory) | `feature/standardized-topology-attrs` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` + NRI UpdatePodSandbox fix |
| [k8snetworkplumbingwg/dra-driver-sriov](https://github.com/k8snetworkplumbingwg/dra-driver-sriov) | [johnahull/dra-driver-sriov](https://github.com/johnahull/dra-driver-sriov) | `feature/dra-topology-co-placement` | Add `resource.kubernetes.io/numaNode` + `cpuSocketID` + NRI plugin index fix |

## Platforms

### Dell XE9680 (AMD)
- **Hardware:** 8x AMD MI300X GPUs, ConnectX-6 NICs, 2-socket Intel, 128 CPUs
- **OS:** Fedora 43, kernel 6.17/6.19
- **K8s:** 1.36.0-rc.0

### Dell PowerEdge R760xa (NVIDIA)
- **Hardware:** 2x NVIDIA A40 GPUs, ConnectX-7 + ConnectX-6 Dx + BlueField-3 NICs, 2-socket Intel Xeon Gold 6548Y+, 128 threads, 256 GB
- **OS:** Fedora 43, kernel 6.19.13
- **K8s:** 1.36.0 GA

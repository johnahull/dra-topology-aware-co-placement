# Patched Repos — DRA Topology-Aware Co-Placement

All forks live under [github.com/johnahull](https://github.com/johnahull).

## Repos with Branches

| Upstream Repo | Fork | Branch | Description |
|---------------|------|--------|-------------|
| [kubevirt/kubevirt](https://github.com/kubevirt/kubevirt) | [johnahull/kubevirt](https://github.com/johnahull/kubevirt) | `feature/dra-vfio-numa-passthrough` | VFIO passthrough via DRA + guest NUMA topology (VEP 115) — 12 files |
| [k8snetworkplumbingwg/dra-driver-sriov](https://github.com/k8snetworkplumbingwg/dra-driver-sriov) | [johnahull/dra-driver-sriov](https://github.com/johnahull/dra-driver-sriov) | `feature/dra-topology-co-placement` | KEP-5304 metadata, DRA hook/driver fixes |
| [ffromani/dra-driver-memory](https://github.com/ffromani/dra-driver-memory) | [johnahull/dra-driver-memory](https://github.com/johnahull/dra-driver-memory) | `feature/dra-topology-co-placement` | Dockerfile + preflight + dependency updates |
| [amd/MxGPU-Virtualization](https://github.com/amd/MxGPU-Virtualization) | [johnahull/MxGPU-Virtualization](https://github.com/johnahull/MxGPU-Virtualization) | `fix/kernel-6.17-compat` | `vm_flags_set()` for kernel 6.3+ |
| [fabiendupont/k8s-dra-topology-coordinator](https://github.com/fabiendupont/k8s-dra-topology-coordinator) | [johnahull/k8s-dra-topology-coordinator](https://github.com/johnahull/k8s-dra-topology-coordinator) | `fix/distance-based-fallback` | pcieRoot → numaNode fallback with CouplingLevel |
| | | `fix/numanode-attribute-namespace` | Per-driver NUMA attribute namespacing |
| | | `fix/pcieroot-constraint-non-pci-drivers` | Skip non-PCI drivers in pcieRoot constraints |
| | | `fix/per-driver-cel-selectors` | Per-driver CEL selectors replacing cross-driver matchAttribute |
| | | `fix/webhook-forward-cel-selectors` | Forward user CEL selectors through webhook |
| | | `test/all-fixes-combined` | Combined branch with all fixes |
| [ROCm/k8s-gpu-dra-driver](https://github.com/ROCm/k8s-gpu-dra-driver) | — (patches on upstream remote) | `develop` | GPU partition fixes, MI210 support |
| | | `feature-auto-partition` | Automatic partition discovery |

## No Patches Needed

| Repo | Notes |
|------|-------|
| [kubernetes-sigs/dra-driver-cpu](https://github.com/kubernetes-sigs/dra-driver-cpu) | Used as-is |

## Platform

- **Hardware:** Dell XE9680 — 8x AMD MI300X GPUs, ConnectX-6 NICs, 2-socket Intel, 128 CPUs
- **OS:** Fedora 43, kernel 6.19
- **K8s:** 1.36.0-rc.0
- **containerd:** rebuilt from HEAD for NRI v0.11.0

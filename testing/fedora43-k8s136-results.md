# DRA Topology-Aware Co-Placement — Fedora 43 + K8s 1.36

**Platform:** Fedora 43 (kernel 6.17.1) + Kubernetes 1.36.0-rc.0 (built from source)
**Hardware:** Dell XE9680 — 2-socket Intel (128 CPUs), 8x AMD MI300X GPUs, 2x ConnectX-6 NICs (8 VFs)
**Container Runtime:** containerd 2.3-dev (built from main, NRI v0.11.0)
**CNI:** Calico v3.29.3
**Date:** 2026-04-14

---

## Summary

Deployed a full DRA topology-aware co-placement stack on Fedora 43 with Kubernetes 1.36 (built from source). Four DRA drivers (CPU, GPU, NIC, memory) allocate devices with NUMA isolation, and `DRAConsumableCapacity` (new in K8s 1.36) enables explicit CPU core and memory reservation per pod. KubeVirt VMs run alongside plain pods, with NIC VFs passed through via VFIO and discovered via KEP-5304 native device metadata.

### What Works

- **4-pod quarter-machine split**: 32 CPUs + 2 GPUs + 2 NICs + 128 GiB memory + 8 GiB hugepages per pod, NUMA-isolated, capacity reserved via `DRAConsumableCapacity`
- **2-pod half-machine split**: 64 CPUs + 4 GPUs + 4 NICs + 256 GiB memory + 16 GiB hugepages per pod
- **Mixed pod + VM workload with full resource allocation**: 2 pods + 2 KubeVirt VMs, all with CPU + memory + hugepages + NICs, NUMA-isolated. Pods get GPUs (ROCm), VMs get NICs (VFIO passthrough via KEP-5304). Pods and VMs share CPU and memory devices on the same NUMA node via `DRAConsumableCapacity`.
- **KEP-5304 native metadata API**: Drivers set `EnableDeviceMetadata(true)`, kubelet handles file writing and CDI mounts automatically
- **DRA CPU exclusive pinning**: CPU driver allocates exclusive cores via `DRAConsumableCapacity`

### What Required Patching

- **AMD GPU DRA driver**: 8 patches — driverVersion fallback, multi-driver claim filter, KEP-5304 metadata, standard pciBusID attribute, VFIO mode (bind to vfio-pci + CDI /dev/vfio), VFIO CDI device skipping, K8s 1.36 API renames
- **SR-IOV NIC DRA driver**: 5 patches — KEP-5304 metadata, NAD optional, skip RDMA for vfio-pci, skip CNI for VFIO, K8s 1.36 API renames
- **DRA Memory driver**: 2 patches — cgroup2 mount filter (Calico workaround), Go 1.26 Dockerfile
- **KubeVirt**: 2 patches — DRA permission skip (virt-controller), KEP-5304 metadata path symlink + dmidecode stub (virt-launcher wrapper)
- **containerd**: Built from main branch for NRI v0.11.0 (Fedora 43 ships v0.8.0 which lacks `UpdatePodSandbox`)

### Known Issues

- **GPU VFIO passthrough to VMs is unstable**: AMD GPU DRA driver discovers GPUs via amdgpu sysfs — binding a PF to vfio-pci removes it from discovery. Without GIM SR-IOV driver, PFs are the only option and they can't be shared. GPU VFIO works for single-driver claims but the driver restarts cause cascading failures.
- **Multi-driver KEP-5304 metadata in single claim**: Kubelet only injects metadata CDI mount for one driver when multiple drivers share a claim. Workaround: use separate ResourceClaims per driver.
- **GPU driver liveness probe**: gRPC health check fails intermittently → constant pod restarts. Fix: remove liveness probe.
- **CDI root path mismatch**: AMD GPU driver defaults to `/etc/cdi`, containerd watches `/var/run/cdi`. Fix: `--cdi-root=/var/run/cdi`.
- **Hostname reset after reboot**: Fedora may reset hostname to `localhost.localdomain`. Fix: `hostnamectl set-hostname`.
- **NIC VFs not persistent**: SR-IOV VF count resets on reboot. Need systemd unit or udev rule.

---

## Setup

### 1. Fedora 43 Install

Fresh install on Dell XE9680. Kernel cmdline:
```
intel_iommu=on iommu=pt default_hugepagesz=2M hugepagesz=2M hugepages=32768
```

No `amdgpu` blacklist — ROCm container mode for GPU DRA driver.

Disabled zram swap:
```bash
sudo swapoff -a && sudo dnf remove -y zram-generator-defaults
```

Extended root LV from 15G to 100G:
```bash
sudo lvextend -L 100G /dev/fedora_j42-h01-000-xe9680/root && sudo xfs_growfs /
```

### 2. K8s 1.36.0-rc.0 from Source

```bash
git clone --depth 1 --branch v1.36.0-rc.0 https://github.com/kubernetes/kubernetes.git
make WHAT="cmd/kubeadm cmd/kubelet cmd/kubectl cmd/kube-apiserver cmd/kube-controller-manager cmd/kube-scheduler cmd/kube-proxy"
sudo cp _output/bin/{kubeadm,kubelet,kubectl,kube-proxy} /usr/local/bin/
```

Go 1.26.2 required. `DRAConsumableCapacity` beta, enabled by default.

### 3. containerd — Built from Main

Fedora 43 containerd 2.1.6 bundles NRI v0.8.0. Memory driver needs v0.11.0 (`UpdatePodSandbox`).

```bash
git clone https://github.com/containerd/containerd.git && cd containerd
make bin/containerd && sudo cp bin/containerd /usr/bin/containerd
```

Config: NRI enabled, SystemdCgroup enabled.

### 4. kubeadm init + Calico

Single-node cluster, control-plane taint removed, Calico v3.29.3 CNI.

### 5. NIC SR-IOV VFs

```bash
echo 4 | sudo tee /sys/class/net/ens40f0np0/device/sriov_numvfs  # NUMA 0
echo 4 | sudo tee /sys/class/net/ens31f0np0/device/sriov_numvfs  # NUMA 1
```

---

## DRA Drivers

| Driver | Devices | NUMA Attribute | Capacity |
|--------|---------|---------------|----------|
| `dra.cpu` | 2 (64 CPUs each) | `dra.cpu/numaNodeID` | `dra.cpu/cpu` (cores) |
| `gpu.amd.com` | 8 MI300X | `gpu.amd.com/numaNode` | — |
| `sriovnetwork` | 8 CX-6 VFs | `dra.net/numaNode` | — |
| `dra.memory` | 2 regular + 2 hugepages | `dra.memory/numaNode` | `size` (bytes) |

---

## KEP-5304 Native Metadata API

Both SR-IOV and AMD GPU drivers use the K8s 1.36 native API:

```go
kubeletplugin.Start(ctx, driver,
    kubeletplugin.EnableDeviceMetadata(true),
    kubeletplugin.MetadataVersions(schema.GroupVersion{
        Group: "metadata.resource.k8s.io", Version: "v1alpha1",
    }),
)
```

Metadata populated on each `kubeletplugin.Device` in `PrepareResult`. Kubelet writes files, generates CDI mounts, cleans up automatically.

In-container path: `/var/run/kubernetes.io/dra-device-attributes/resourceclaims/{claimName}/{requestName}/{driver}-metadata.json`

KubeVirt reads from `/var/run/dra-device-attributes/` — fixed with virt-launcher wrapper that creates a symlink.

---

## Test Results

### Quarter-Machine Pods (4 pods, DRAConsumableCapacity)

| Pod | NUMA | CPU | GPUs | NICs | Memory | Hugepages |
|-----|------|-----|------|------|--------|-----------|
| q0 | 0 | 32 cores | gpu-9, gpu-17 | 1d:00.2, 1d:00.3 | 128 GiB | 8 GiB |
| q1 | 0 | 32 cores | gpu-1, gpu-25 | 1d:00.4, 1d:00.5 | 128 GiB | 8 GiB |
| q2 | 1 | 32 cores | gpu-33, gpu-41 | 9f:00.4, 9f:00.5 | 128 GiB | 8 GiB |
| q3 | 1 | 32 cores | gpu-49, gpu-57 | 9f:00.2, 9f:00.3 | 128 GiB | 8 GiB |

Two pods share each CPU and memory device via `DRAConsumableCapacity`.

### Half-Machine Pods (2 pods, DRAConsumableCapacity)

| Pod | NUMA | CPU | GPUs | NICs | Memory | Hugepages |
|-----|------|-----|------|------|--------|-----------|
| half0 | 0 | 64 cores | 4x MI300X | 4x CX-6 VFs | 256 GiB | 16 GiB |
| half1 | 1 | 64 cores | 4x MI300X | 4x CX-6 VFs | 256 GiB | 16 GiB |

### Mixed Pod + VM with Full Resource Allocation (2 pods + 2 VMs)

All 5 device types allocated per workload. Pods and VMs share CPU and memory devices on the same NUMA node via `DRAConsumableCapacity`.

| Workload | Type | NUMA | CPU | GPUs | NICs | Memory | Hugepages |
|----------|------|------|-----|------|------|--------|-----------|
| pod-numa0 | Pod | 0 | 16 cores | gpu-1 (`1b:00.0`), gpu-9 (`3d:00.0`) | `1d:00.3`, `1d:00.5` | 128 GiB | 8 GiB |
| pod-numa1 | Pod | 1 | 16 cores | gpu-33 (`9d:00.0`), gpu-57 (`dd:00.0`) | `9f:00.3`, `9f:00.4` | 128 GiB | 8 GiB |
| vm-numa0 | KubeVirt VM | 0 | 16 cores | — | `1d:00.4` (VFIO) | 64 GiB | 4 GiB |
| vm-numa1 | KubeVirt VM | 1 | 16 cores | — | `9f:00.2` (VFIO) | 64 GiB | 4 GiB |

VMs use separate ResourceClaims per driver (CPU, NIC, memory) to work around the multi-driver KEP-5304 metadata limitation.

---

## Patches

### AMD GPU DRA Driver — 8 patches

| # | File | Change |
|---|------|--------|
| 1 | `pkg/amdgpu/amdgpu.go` | Fallback `"0.0.0"` when driver version empty |
| 2 | `cmd/gpu-kubeletplugin/state.go` | Multi-driver claim filter (`result.Driver`) |
| 3 | `cmd/gpu-kubeletplugin/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` + populate Metadata |
| 4 | `cmd/gpu-kubeletplugin/deviceinfo.go` | Standard `resource.kubernetes.io/pciBusID` attribute |
| 5 | Various | `CDIDeviceIDs` → `CdiDeviceIds` for K8s 1.36 |
| 6 | `api/.../api.go` | `Driver` field in `GpuConfig` for VFIO mode |
| 7 | `cmd/gpu-kubeletplugin/state.go` | `applyVFIOConfig()` + `bindToVFIO()` + `getIOMMUGroup()` |
| 8 | `cmd/gpu-kubeletplugin/state.go` + `cdi.go` | VFIO skips common CDI device; `GetClaimDevicesVFIO()` |

### SR-IOV DRA Driver — 5 patches

| # | File | Change |
|---|------|--------|
| 1 | `pkg/driver/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` |
| 2 | `pkg/driver/dra_hook.go` | Populate `Metadata` with `resource.kubernetes.io/pciBusID` |
| 3 | `pkg/devicestate/state.go` | NAD lookup optional for VFIO passthrough |
| 4 | `pkg/devicestate/state.go` | Skip RDMA for vfio-pci bound devices |
| 5 | `pkg/nri/nri.go` | Skip CNI attach/detach for VFIO devices |

### DRA Memory Driver — 2 patches

| # | File | Change |
|---|------|--------|
| 1 | `pkg/sysinfo/preflight.go` | Filter cgroup2 mounts to `/sys/fs/cgroup` (Calico creates second mount) |
| 2 | `Dockerfile` | `golang:1.24` → `golang:1.26` |

### KubeVirt — virt-controller patch + virt-launcher wrapper

| Component | Change |
|-----------|--------|
| virt-controller | Skip permittedHostDevices check for DRA devices (`ClaimRequest != nil`) |
| virt-launcher | Wrapper scripts create symlink `/var/run/dra-device-attributes` → K8s 1.36 metadata path; dmidecode stub |
| virt-operator | Scaled to 0 to prevent image reversion |

### containerd

Built from main branch (NRI v0.8.0 → v0.11.0) for memory driver `UpdatePodSandbox` support.

---

## Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| Fedora | 43 | ISO install |
| Kernel | 6.17.1-300.fc43 | Fedora default |
| Kubernetes | v1.36.0-rc.0 | Built from source |
| Go | 1.26.2 | go.dev |
| containerd | 2.3-dev (main) | Built from source |
| Calico | v3.29.3 | Upstream manifest |
| KubeVirt | v1.8.1 | Upstream + patches |
| DRA CPU driver | latest | Upstream image |
| DRA SR-IOV driver | patched (5) | Built locally |
| AMD GPU DRA driver | patched (8) | Built locally |
| DRA Memory driver | patched (2) | Built locally |

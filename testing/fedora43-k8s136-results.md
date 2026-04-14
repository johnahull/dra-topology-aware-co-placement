# DRA Topology-Aware Co-Placement — Fedora 43 + K8s 1.36

**Platform:** Fedora 43 (kernel 6.17.1) + Kubernetes 1.36.0-rc.0 (built from source)
**Hardware:** Dell XE9680 — 2-socket Intel (128 CPUs), 8x AMD MI300X GPUs, 2x ConnectX-6 NICs (8 VFs)
**Container Runtime:** containerd 2.3-dev (built from main, NRI v0.11.0)
**CNI:** Calico v3.29.3
**Date:** 2026-04-14

---

## What We Proved

### Full 4-Driver NUMA-Isolated Machine Partitioning

Four pods, each getting a quarter of the machine with **explicit capacity reservation** via `DRAConsumableCapacity`:

| Pod | NUMA | CPU | GPUs | NICs | Memory | Hugepages |
|-----|------|-----|------|------|--------|-----------|
| q0 | 0 | 32 cores | gpu-9, gpu-17 | 1d:00.2, 1d:00.3 | 128 GiB | 8 GiB |
| q1 | 0 | 32 cores | gpu-1, gpu-25 | 1d:00.4, 1d:00.5 | 128 GiB | 8 GiB |
| q2 | 1 | 32 cores | gpu-33, gpu-41 | 9f:00.4, 9f:00.5 | 128 GiB | 8 GiB |
| q3 | 1 | 32 cores | gpu-49, gpu-57 | 9f:00.2, 9f:00.3 | 128 GiB | 8 GiB |

Also demonstrated 2-pod half-machine split: 64 CPUs + 4 GPUs + 4 NICs + 256 GiB memory + 16 GiB hugepages per NUMA node.

### Key: `DRAConsumableCapacity` (K8s 1.36)

This feature (beta, enabled by default in K8s 1.36) allows DRA drivers to publish **consumable capacity** on devices, and claims to **request specific amounts**. The scheduler and kubelet enforce exclusive capacity accounting:

- **CPU**: 2 pods share `cpudevnuma000` with 32 exclusive cores each
- **Memory**: 2 pods share `memory-gt5gdg` with 128 GiB each
- **Hugepages**: 2 pods share `hugepages-2mi-rjbmfh` with 8 GiB each
- **GPUs and NICs**: Exclusive (not shared — each pod gets distinct devices)

This eliminates any need for cpuset swap hacks — the CPU driver handles exclusive pinning natively.

---

## Setup

### 1. Fedora 43 Install

Fresh install on Dell XE9680. Kernel cmdline:
```
intel_iommu=on iommu=pt default_hugepagesz=2M hugepagesz=2M hugepages=32768
```

No `amdgpu` blacklist — ROCm container mode.

Disabled zram swap (Fedora 43 default):
```bash
sudo swapoff -a
sudo dnf remove -y zram-generator-defaults
```

Extended root LV from 15G to 100G (444G VG had space):
```bash
sudo lvextend -L 100G /dev/fedora_j42-h01-000-xe9680/root
sudo xfs_growfs /
```

### 2. K8s 1.36.0-rc.0 from Source

```bash
git clone --depth 1 --branch v1.36.0-rc.0 https://github.com/kubernetes/kubernetes.git
cd kubernetes
make WHAT="cmd/kubeadm cmd/kubelet cmd/kubectl cmd/kube-apiserver cmd/kube-controller-manager cmd/kube-scheduler cmd/kube-proxy"
sudo cp _output/bin/{kubeadm,kubelet,kubectl,kube-proxy} /usr/local/bin/
```

Required Go 1.26.2. `DRAConsumableCapacity` is beta and enabled by default — no feature gates needed.

### 3. containerd — Built from Main (NRI v0.11.0)

Fedora 43 ships containerd 2.1.6 which bundles NRI v0.8.0. The DRA memory driver requires NRI v0.11.0 (for `UpdatePodSandbox` support). Built containerd from HEAD:

```bash
git clone https://github.com/containerd/containerd.git
cd containerd
make bin/containerd
sudo cp bin/containerd /usr/bin/containerd
```

containerd config (`/etc/containerd/config.toml`):
```toml
[plugins."io.containerd.nri.v1.nri"]
  disable = false

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

### 4. kubeadm init

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.0-rc.0
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

```bash
sudo kubeadm init --config=kubeadm-config.yaml
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/calico.yaml
```

### 5. NIC SR-IOV VFs

```bash
echo 4 | sudo tee /sys/class/net/ens40f0np0/device/sriov_numvfs  # NUMA 0
echo 4 | sudo tee /sys/class/net/ens31f0np0/device/sriov_numvfs  # NUMA 1
```

Not persistent across reboot — needs systemd unit or udev rule.

---

## DRA Drivers Deployed

### DRA CPU Driver (`dra.cpu`)

Upstream image. DaemonSet in `kube-system`. Key flags:
- `--cpu-device-mode=grouped` — 1 device per NUMA node, 64 CPUs each
- `--hostname-override=$(NODE_NAME)` — must use `$(VAR)` K8s syntax, not `${VAR}`

Publishes capacity: `dra.cpu/cpu` (number of CPUs consumable per device).

### DRA SR-IOV NIC Driver (`sriovnetwork.k8snetworkplumbingwg.io`)

Built from patched source. Deployed via Helm. Requires `SriovResourcePolicy` for device discovery.

Default VFIO config added to DeviceClass `spec.config` — eliminates need for per-claim opaque `VfConfig`.

### AMD GPU DRA Driver (`gpu.amd.com`)

Built from patched source. Deployed as standalone DaemonSet (not via GPU operator — too many dependencies for plain K8s). Init container waits for `amdgpu` kernel module. Privileged, mounts `/dev` and `/sys`.

Images imported to containerd via:
```bash
sudo podman save localhost/<image> | sudo ctr -n k8s.io images import -
```

### DRA Memory Driver (`dra.memory`)

Built from patched source. Publishes 4 devices: 2 regular memory + 2 hugepages zones. Publishes consumable capacity: `size` (bytes of memory/hugepages available per NUMA node).

---

## KEP-5304 Native Metadata API (K8s 1.36)

Both the SR-IOV and AMD GPU drivers were updated to use the native KEP-5304 metadata API.

### How It Works

```go
helper, err := kubeletplugin.Start(ctx, driver,
    kubeletplugin.EnableDeviceMetadata(true),
    kubeletplugin.MetadataVersions(schema.GroupVersion{
        Group: "metadata.resource.k8s.io", Version: "v1alpha1",
    }),
    // ...
)
```

In `PrepareResult`, populate `Metadata` on each device:

```go
dev.Metadata = &kubeletplugin.DeviceMetadata{
    Attributes: map[string]resourceapi.DeviceAttribute{
        "resource.kubernetes.io/pciBusID": {StringValue: &pciAddr},
    },
}
```

The kubelet handles file writing, CDI mount generation, and cleanup automatically.

### What This Replaces

Without the native API, KEP-5304 would require manual implementation:
1. Writing JSON metadata files during PrepareResources
2. Adding CDI mount directives for metadata injection
3. NRI hooks to inject mounts into containers
4. Per-request metadata aggregation to avoid mount collisions

The native API eliminates all of this — the kubelet handles it automatically.

### K8s 1.36 API Renames

The `kubelet/pkg/apis/dra/v1beta1` proto renamed:
- `CDIDeviceIDs` → `CdiDeviceIds`
- `GetCDIDeviceIDs()` → `GetCdiDeviceIds()`

The `kubeletplugin.Device` wrapper still uses `CDIDeviceIDs`.

---

## Patches Applied

### SR-IOV DRA Driver — 5 patches

| # | File | Change |
|---|------|--------|
| 1 | `pkg/driver/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` |
| 2 | `pkg/driver/dra_hook.go` | Populate `Metadata` with `resource.kubernetes.io/pciBusID` on each device |
| 3 | `pkg/devicestate/state.go` | NAD lookup optional for VFIO passthrough |
| 4 | `pkg/devicestate/state.go` | Skip RDMA for vfio-pci bound devices |
| 5 | `pkg/nri/nri.go` | Skip CNI attach/detach for VFIO devices |

Plus: `CDIDeviceIDs` → `CdiDeviceIds` rename, `go.mod` updated to K8s 1.36 RC + controller-runtime@main.

The native KEP-5304 API eliminates the need for manual metadata file writing, cleanup, NRI mount hooks, and per-request aggregation.

### AMD GPU DRA Driver — 5 patches

| # | File | Change |
|---|------|--------|
| 1 | `pkg/amdgpu/amdgpu.go` | Fallback `"0.0.0"` when kernel driver version is empty (both early-return paths) |
| 2 | `cmd/gpu-kubeletplugin/state.go` | Filter `result.Driver != consts.DriverName` for multi-driver claims |
| 3 | `cmd/gpu-kubeletplugin/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` + populate `Metadata` with pciBusID, productName, family, numaNode |
| 4 | `cmd/gpu-kubeletplugin/deviceinfo.go` | Add `resource.kubernetes.io/pciBusID` to ResourceSlice attributes (Gap 3 fix) |
| 5 | `cmd/gpu-kubeletplugin/state.go` + `driver.go` | `CDIDeviceIDs` → `CdiDeviceIds` for K8s 1.36 proto |

Plus: `go.mod` + `vendor/` updated to K8s 1.36 RC.

### DRA Memory Driver — 2 patches

| # | File | Change |
|---|------|--------|
| 1 | `pkg/sysinfo/preflight.go` | Filter cgroup2 mounts to `/sys/fs/cgroup` only — Calico creates a second cgroup2 mount at `/run/calico/cgroup` that triggers `ErrCGroupV2Repeated` |
| 2 | `Dockerfile` | `golang:1.24` → `golang:1.26` for K8s 1.36 dependency compatibility |

Plus: `go.mod` updated to K8s 1.36 RC.

### containerd — Built from Main

| Issue | Detail |
|-------|--------|
| Fedora 43 containerd 2.1.6 bundles NRI v0.8.0 | Memory driver needs v0.11.0 for `UpdatePodSandbox` |
| Fix: built containerd from HEAD (NRI v0.11.0) | Replaced `/usr/bin/containerd` with built binary |

---

## Issues Found

### containerd NRI Version Mismatch

Fedora 43's containerd 2.1.6 bundles NRI v0.8.0. The DRA memory driver uses `containerd/nri v0.11.0` and implements `UpdatePodSandbox` which is not supported in v0.8.0. containerd immediately closes the ttrpc connection: `ttrpc: server closed`.

**Fix:** Build containerd from HEAD (has NRI v0.11.0). This is a packaging issue — upstream containerd main has the fix, but the Fedora package is behind.

### AMD GPU Driver Instability

The GPU DRA driver (`gpu.amd.com`) restarts 3-4 times during rapid pod scheduling. Error: `terminated signal received`. The driver recovers and pods eventually start, but there's a ~30s delay.

**Root cause:** Not fully investigated. Likely a resource or timeout issue in the kubelet plugin framework during concurrent PrepareResources calls. Not a hard crash — the DaemonSet restarts the pod and it re-registers successfully.

### `DRAConsumableCapacity` Capacity Key Names

Capacity keys in claims must use the **unqualified** name as published in the ResourceSlice, not the qualified `domain/name` form:
- **Works:** `size: "256Gi"` (matches ResourceSlice key `size`)
- **Fails:** `dra.memory/size: "256Gi"` (scheduler can't match)

Exception: CPU driver uses `dra.cpu/cpu` which IS qualified in the ResourceSlice.

### GPU Operator Not Suitable for Plain K8s

The AMD GPU operator (`ROCm/gpu-operator`) has too many dependencies for plain K8s:
- Requires cert-manager CRDs (for KMM)
- NFD CRDs needed
- Controller image has `runAsNonRoot` conflict
- `DeviceConfig` CR doesn't support DRA driver image override

**Solution:** Deploy the GPU DRA driver as a standalone DaemonSet.

---

## ResourceSlice Summary

| Driver | Devices | NUMA Attribute | Capacity |
|--------|---------|---------------|----------|
| `dra.cpu` | 2 (64 CPUs each) | `dra.cpu/numaNodeID` | `dra.cpu/cpu` (consumable cores) |
| `gpu.amd.com` | 8 MI300X | `gpu.amd.com/numaNode` | — |
| `sriovnetwork` | 8 CX-6 VFs | `dra.net/numaNode` | — |
| `dra.memory` | 2 regular + 2 hugepages | `dra.memory/numaNode` | `size` (consumable bytes) |

---

## Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| Fedora | 43 | Installed from ISO |
| Kernel | 6.17.1-300.fc43 | Fedora default |
| Kubernetes | v1.36.0-rc.0 | Built from source |
| Go | 1.26.2 | Downloaded from go.dev |
| containerd | 2.3-dev (main) | Built from source (NRI v0.11.0) |
| Calico | v3.29.3 | Upstream manifest |
| Helm | v3.x | get-helm-3 script |
| DRA CPU driver | latest | Upstream image |
| DRA SR-IOV driver | patched | Built from `/home/jhull/devel/kubernetes/dra-driver-sriov` |
| AMD GPU DRA driver | patched | Built from `/home/jhull/devel/amd/k8s-gpu-dra-driver` |
| DRA Memory driver | patched | Built from `/home/jhull/devel/kubernetes/dra-driver-memory` |

---

## Test Configurations

### Half-Machine Split (2 pods, 5 device types with capacity)

Each pod gets one full NUMA node: 64 CPUs + 4 GPUs + 4 NICs + 256 GiB memory + 16 GiB hugepages.

```yaml
requests:
- name: cpu
  exactly:
    deviceClassName: dra.cpu
    count: 1
    selectors:
    - cel:
        expression: 'device.attributes["dra.cpu"].numaNodeID == 0'
- name: gpu
  exactly:
    deviceClassName: gpu.amd.com
    count: 4
    selectors:
    - cel:
        expression: 'device.attributes["gpu.amd.com"].numaNode == 0'
- name: nic
  exactly:
    deviceClassName: sriovnetwork.k8snetworkplumbingwg.io
    count: 4
    selectors:
    - cel:
        expression: 'device.attributes["dra.net"].numaNode == 0'
- name: mem
  exactly:
    deviceClassName: dra.memory
    count: 1
    selectors:
    - cel:
        expression: 'device.attributes["dra.memory"].numaNode == 0 && device.attributes["dra.memory"].hugeTLB == false'
    capacity:
      requests:
        size: "256Gi"
- name: hugepages
  exactly:
    deviceClassName: dra.hugepages-2m
    count: 1
    selectors:
    - cel:
        expression: 'device.attributes["dra.memory"].numaNode == 0'
    capacity:
      requests:
        size: "16Gi"
```

### Quarter-Machine Split (4 pods, 5 device types with capacity)

Each pod gets half a NUMA node: 32 CPUs + 2 GPUs + 2 NICs + 128 GiB memory + 8 GiB hugepages.

Same structure as above with `count` halved and capacity halved. Two pods share each CPU and memory device via `DRAConsumableCapacity`.

---

## Remaining Work

| Item | Status |
|------|--------|
| DRA CPU pinning verification inside container | Not yet verified (cpuset.cpus should reflect 32 exclusive cores) |
| Topology coordinator deployment | Not yet deployed on Fedora |
| KubeVirt deployment | Not yet deployed on Fedora |
| ROCm workload test (PyTorch/HIP) | Not yet tested |
| KEP-5304 metadata verification in pod | Not yet checked (should be at `/var/run/kubernetes.io/dra-device-attributes/`) |
| GPU driver stability investigation | Restarts 3-4 times during rapid scheduling |
| Submit patches upstream | SR-IOV: 5, AMD GPU: 5, Memory: 2 |
| NIC VF persistence across reboot | Needs systemd unit or udev rule |

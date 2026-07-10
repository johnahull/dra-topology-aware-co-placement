# XE9680 MI300X VFIO DRA Session — 2026-06-01/02

## System

- **Host:** j42-h01-000-xe9680.rdu3.labs.perfscale.redhat.com
- **IP:** 10.6.62.52
- **OS:** Fedora Linux 44 (Server Edition), kernel 6.19.10-300.fc44.x86_64
- **K8s:** v1.36.1 (kubeadm, single node)
- **Container runtime:** containerd 2.2.3
- **KubeVirt:** built from main + feature/dra-all-patches (9 patches)
- **KubeVirt feature gates:** GPUsWithDRA, HostDevicesWithDRA, HostDevices, ReservedOverheadMemlock, Root
- **Root LV:** extended from 15GB to 50GB during session (was causing disk pressure)

## Hardware

- 8x AMD Instinct MI300X OAM GPUs (192GB VRAM each, 262GB BAR)
- 4x NUMA nodes (0-3), 2 GPUs per NUMA
- Intel Xeon w/ SNC-2 (SLIT distances: 10/12 within socket, 21 cross-socket)
- IOMMU enabled (intel_iommu=on, iommu=pt)

### GPU-to-NUMA Mapping

| GPU PCI | NUMA | numaNode List | IOMMU Group |
|---------|------|---------------|-------------|
| 0000:1b:00.0 | 0 | [0, 1] | 50 |
| 0000:3d:00.0 | 1 | [1, 0] | 36 |
| 0000:4e:00.0 | 1 | [1, 0] | 24 |
| 0000:5f:00.0 | 0 | [0, 1] | 12 |
| 0000:9d:00.0 | 2 | [2, 3] | 101 |
| 0000:bd:00.0 | 3 | [3, 2] | 88 |
| 0000:cd:00.0 | 3 | [3, 2] | 77 |
| 0000:dd:00.0 | 2 | [2, 3] | 66 |

## Components Deployed

| Component | Image / Source | Status |
|-----------|---------------|--------|
| AMD GPU Operator | localhost/amd-gpu-operator:vfio-test (built from ROCm/gpu-operator main) | Running (NFD + labeling only) |
| k8s-gpu-dra-driver | localhost/k8s-gpu-dra-driver:vfio-test (johnahull/feature/vfio-kep5304-combined) | Running |
| DRA CPU driver | ghcr.io/johnahull/dra-topology-drivers/dra-cpu-driver:numanode-list | Running |
| DRA Memory driver | ghcr.io/johnahull/dra-topology-drivers/dra-memory-driver:numanode-list | Running |
| DRA SR-IOV driver | ghcr.io/johnahull/dra-topology-drivers/dra-sriov-driver:numanode-list | Running |
| KubeVirt | 10.6.62.52:5000/*:dra-test (built from feature/dra-all-patches) | Running |
| Topology Coordinator | ghcr.io/johnahull/dra-topology-drivers/topology-coordinator:latest | Running (device classes generated) |

## What Worked

### 1. AMD GPU DRA Driver — VFIO Discovery + KEP-5304

Branch: `johnahull/k8s-gpu-dra-driver:feature/vfio-kep5304-combined`

- Discovers GPUs bound to vfio-pci as `type=vfio` devices
- Discovers GPUs on amdgpu as regular `type=amdgpu` devices
- Both types coexist in the same ResourceSlice
- KEP-5304 device metadata: `resource.kubernetes.io/pciBusID`, `pcieRoot`, `numaNode` (list)
- numaNode list uses upstream `deviceattribute.GetNUMANodeListByPCIBusID()` helper from kubernetes staging
- SLIT-based equidistant NUMA nodes: GPU on NUMA 0 reports `[0, 1]` (peer socket nodes)
- CDI injects `/dev/vfio/<iommu_group>` and `/dev/vfio/vfio` for VFIO devices
- Configure/Unconfigure handles bind/unbind to vfio-pci with per-GPU locking
- Multi-driver claim filter (skip allocation results from other drivers)
- Driver version fallback to "0.0.0" when kernel module has no version string

### 2. KubeVirt DRA NUMA Topology

Branch: `johnahull/kubevirt:feature/dra-all-patches` (8 patches + VFIO fixes)

- Guest NUMA cell construction from DRA KEP-5304 metadata
- Reads `resource.kubernetes.io/numaNode` list attribute from metadata JSON (raw parse for v0.34 compat)
- GPU PCI-to-NUMA override mapping via `buildDRANUMAOverrides`
- `transformDRAOverridesToGuestCells` maps host NUMA IDs to guest cell IDs
- `PlacePCIDevicesWithNUMAAlignment` accepts optional NUMA overrides for pxb-pcie placement
- DRA CPU claims skip cpumanager node selector
- VM-scoped persistent ResourceClaims for DRA device passthrough

### 3. VFIO Pod Tests (non-VM)

All VFIO DRA tests passed for container workloads:
- Single VFIO GPU claim: `/dev/vfio/66` injected
- Multi VFIO GPU claim (2 devices): both `/dev/vfio/66` and `/dev/vfio/77`
- Regular amdgpu claim: `/dev/dri/card1`, `/dev/kfd` — no VFIO
- KEP-5304 topology selector (`pciBusID`): correct device targeting
- Allocation exclusivity: second pod pending when device claimed

### 4. VM NUMA Topology (without GPU)

VM with DRA CPU + memory claims on NUMA 0:
- Guest NUMA cell 0: cpus=0-3, memory=8GB
- Host NUMA 0 → guest cell 0 mapping correct
- DRA metadata read correctly from virt-launcher

### 5. Topology Coordinator

- Device classes generated for eighth/quarter/half/full partitions
- Webhook expansion of single partition claim into sub-requests (GPU, CPU, memory, SR-IOV)
- CEL selectors use `includes()` for numaNode list attributes

## What Didn't Work: MI300X GPU VFIO Passthrough in VMs

### Root Cause: MI300X PCI Config Space After VFIO Reset

The MI300X's PCI config space becomes all 0xFF (unreadable) after a VFIO device reset. This prevents libvirt from reading the PCI header type and starting QEMU.

**Symptoms:**
```
internal error: Unknown PCI header type '127' for device '0000:1b:00.0'
```

**Timeline:**
1. Fresh boot: config space readable (vendor 0x1002, device 0x74a1, header type 0x00)
2. Bind to vfio-pci: config space readable (confirmed immediately after bind)
3. QEMU opens VFIO device: kernel resets the device
4. After reset: config space returns all 0xFF permanently
5. Subsequent VM starts fail because libvirt reads sysfs config before starting QEMU
6. Device does not recover after PCI remove + rescan (device disappears entirely)
7. Only a full host reboot recovers the device

**Comparison with NVIDIA:**
- NVIDIA A40/H100: config space remains readable after VFIO reset
- AMD MI300X: config space becomes permanently unreadable

**This is an AMD firmware/hardware issue, not a software bug.**

### Additional Fixes Applied (would work once VFIO reset issue is resolved)

1. **`<locked/>`** added to `<memoryBacking>` for VFIO VMs — QEMU needs `mem-lock=on` for DMA
2. **`x-pci-hole64-size=274877906944`** — MI300X has 262GB BAR that doesn't fit in default q35 PCI hole
3. **`CAP_SYS_RESOURCE` + root mode** — cherry-picked PR #17696 for VFIO memlock

### Files Modified

**k8s-gpu-dra-driver (feature/vfio-kep5304-combined):**
- `cmd/gpu-kubeletplugin/deviceinfo.go` — numaNode list via `GetNUMANodeListByPCIBusID()`
- `cmd/gpu-kubeletplugin/driver.go` — VFIO metadata (pciBusID, numaNode list)
- `go.mod` — replace directives for local kubernetes staging (numaNode list helper)

**kubevirt (feature/dra-all-patches + session fixes):**
- `pkg/dra/utils.go` — raw JSON parse for `IntValues` numaNode list, `GetNUMANodeForClaim`
- `pkg/dra/BUILD.bazel` — added `resource/v1` dep
- `pkg/virt-launcher/virtwrap/api/schema.go` — added `Locked` struct to `MemoryBacking`
- `pkg/virt-launcher/virtwrap/converter/converter.go` — `<locked/>` + `x-pci-hole64-size` for VFIO VMs, imports
- `pkg/virt-launcher/virtwrap/converter/BUILD.bazel` — added `//pkg/dra` dep
- `pkg/virt-launcher/virtwrap/converter/pci-placement.go` — optional NUMA overrides param
- `pkg/virt-controller/services/renderresources.go` — fix ClaimRequest string type
- `pkg/virt-launcher/virtwrap/device/hostdevice/dra/gpu_hostdev.go` — managed='no' (original)
- Cherry-picked `80454b63c9` (force root + CAP_SYS_RESOURCE for VFIO VMIs)
- `hack/dockerized` — rsync --no-owner --no-group fix for podman rootless

## Next Steps

1. **File AMD bug** for MI300X VFIO reset config space corruption
2. **Test on system with NVIDIA GPUs** to verify the full pipeline end-to-end (known working from R760xa session)
3. **Test on MI210/MI250** to see if the VFIO reset issue is specific to MI300X
4. **GPU Operator VFIO binding** — use the operator's vfio_bind.sh to bind at boot before DRA driver starts
5. **Persist VFIO modules** — add `vfio_pci` and `vfio_iommu_type1` to `/etc/modules-load.d/`
6. **Persist hugepages** — add kernel boot param `hugepagesz=1G hugepages=12`

## Setup Checklist for Future Deployments

```bash
# 1. Prerequisites
sudo modprobe vfio_pci
sudo modprobe vfio_iommu_type1
echo 12 | sudo tee /sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages

# 2. Bind GPU to vfio-pci (before DRA driver starts)
echo '0000:XX:00.0' | sudo tee /sys/bus/pci/devices/0000:XX:00.0/driver/unbind
echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/0000:XX:00.0/driver_override
echo '0000:XX:00.0' | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
echo '' | sudo tee /sys/bus/pci/devices/0000:XX:00.0/driver_override

# 3. Deploy GPU operator (NFD + labeling)
helm install gpu-operator <chart> -n kube-amd-gpu --create-namespace \
  -f gpu-operator-vfio-values.yaml

# 4. Deploy DRA driver with PF passthrough enabled
helm install gpu-dra-driver <chart> -n kube-amd-gpu \
  --set kubeletPlugin.enablePfPassthrough=true \
  --set image.repository=<image> --set image.tag=<tag>

# 5. Deploy KubeVirt with DRA feature gates
kubectl create -f kubevirt-operator.yaml
kubectl create -f kubevirt-cr.yaml  # with GPUsWithDRA, HostDevicesWithDRA, HostDevices, Root, ReservedOverheadMemlock

# 6. Create VM
kubectl apply -f vm-numa0-manual.yaml
```

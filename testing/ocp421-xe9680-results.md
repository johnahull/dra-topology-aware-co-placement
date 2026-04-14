# DRA Topology-Aware Co-Placement — Testing Results

**Platform:** OpenShift 4.21 (K8s 1.34.5) SNO on Dell XE9680
**Hardware:** 2-socket Intel (128 CPUs), 8x AMD MI300X GPUs, 2x ConnectX-6 NICs (8 VFs)
**Dates:** 2026-04-09 to 2026-04-14

---

## What We Proved

### 1. Full 3-Driver DRA NUMA Isolation

Four pods, each getting a quarter of the machine — 2 GPUs + 2 NIC VFs from the same NUMA node. All allocated via DRA with CEL selectors. Zero cross-NUMA contamination.

| Pod | NUMA | GPUs | NICs |
|-----|------|------|------|
| q0 | 0 | gpu-1, gpu-25 | 1d:00.2, 1d:00.3 |
| q1 | 0 | gpu-9, gpu-17 | 1d:00.4, 1d:00.5 |
| q2 | 1 | gpu-33, gpu-41 | 9f:00.2, 9f:00.5 |
| q3 | 1 | gpu-49, gpu-57 | 9f:00.3, 9f:00.4 |

Also demonstrated 2-pod half-machine split with CPU + 4 GPUs + 4 NICs per NUMA node.

### 2. KubeVirt VM with DRA + 2 Guest NUMA Nodes

VM with GPU VFs (device plugin) + NIC VFs (DRA + KEP-5304), running with 2 guest NUMA nodes. VEP 115 places PCI devices on per-NUMA pxb-pcie expander buses. Guest sees correct `numa_node` for all devices.

### 3. KEP-5304 Device Metadata End-to-End

SR-IOV driver writes PCI BDF metadata → NRI injects mount → pod sees metadata at `/var/run/dra-device-attributes/{claim}/{request}/` → KubeVirt reads BDF → creates `<hostdev>` in domain XML.

### 4. Topology Coordinator Partition Expansion

Webhook correctly expands simple partition claims into per-driver sub-requests with `matchAttribute` constraints. Coordinator discovers devices from all 4 drivers (CPU, GPU, NIC, memory) and creates partition DeviceClasses (eighth/quarter/half/full).

### 5. Cross-Driver NUMA Allocation

`matchAttribute: dra.net/numaNode` constraint forces scheduler to allocate CPU + GPU + NIC from the same NUMA node in a single ResourceClaim.

---

## DRA Drivers Deployed

| Driver | Source | Devices | NUMA Attribute |
|--------|--------|---------|---------------|
| DRA CPU | `kubernetes-sigs/dra-driver-cpu` | 2 (64 CPUs each) | `dra.cpu/numaNodeID` |
| DRA SR-IOV | `k8snetworkplumbingwg/dra-driver-sriov` (7 patches) | 8 NIC VFs (4 per NUMA) | `dra.net/numaNode` |
| AMD GPU DRA | `ROCm/k8s-gpu-dra-driver` (2 patches) | 8 MI300X (4 per NUMA) | `gpu.amd.com/numaNode` |
| DRA Memory | `kad/dra-driver-memory` | 4 zones (2 per NUMA) | `dra.memory/numaNode` |
| Topology Coordinator | `fabiendupont/k8s-dra-topology-coordinator` (1 patch) | — | Maps all → `numaNode` |

---

## Patches Required

### SR-IOV DRA Driver — 7 patches

All in `/home/jhull/devel/kubernetes/dra-driver-sriov/`.

**Patch 1: KEP-5304 metadata write** (`pkg/devicestate/state.go`)

During `prepareDevices()`, after all devices for a request are prepared, write an aggregated JSON metadata file containing `resource.kubernetes.io/pciBusID` for each device. Add a CDI mount to inject it into the pod at `/var/run/dra-device-attributes/{claimName}/{requestName}/`.

```go
// In prepareDevices(), after the per-device loop:
for requestName, devices := range requestDevices {
    metadataHostDir := filepath.Join(s.pluginDataDir, "dra-metadata", string(claim.UID), requestName)
    os.MkdirAll(metadataHostDir, 0755)
    // Build aggregated metadata JSON with all devices for this request
    // Write to metadataHostDir/sriovnetwork.k8snetworkplumbingwg.io-metadata.json
    // Add one CDI mount per request (not per device)
}
```

**Patch 2: NAD lookup optional** (`pkg/devicestate/state.go`)

Skip `NetworkAttachmentDefinition` lookup when `config.NetAttachDefName` is empty. VFIO passthrough doesn't need CNI config.

```go
if config.NetAttachDefName != "" {
    // ... existing NAD lookup
} else {
    logger.V(2).Info("No NetAttachDefName specified, skipping CNI config (VFIO passthrough mode)")
}
```

**Patch 3: Skip RDMA for vfio-pci** (`pkg/devicestate/state.go`)

RDMA device entries are removed when VF is bound to vfio-pci. Skip RDMA handling:

```go
if config.Driver != "vfio-pci" {
    rdmaDeviceNodes, rdmaEnvs, err = s.handleRDMADevice(...)
}
```

**Patch 4: Metadata cleanup** (`pkg/devicestate/state.go`)

In `Unprepare()`, remove the metadata directory for the claim:

```go
metadataDir := filepath.Join(s.pluginDataDir, "dra-metadata", claimUID)
os.RemoveAll(metadataDir)
```

**Patch 5: Skip CNI for VFIO** (`pkg/nri/nri.go`)

In `RunPodSandbox` and `StopPodSandbox`, skip CNI attach/detach when `device.NetAttachDefConfig` is empty. Prevents CRI-O panic on empty CNI result.

**Patch 6: NRI CreateContainer hook** (`pkg/nri/nri.go`)

CRI-O processes CDI `deviceNodes` but not CDI `mounts`. Added `CreateContainer` hook that reads mounts from prepared devices and injects them via `ContainerAdjustment`:

```go
func (p *Plugin) CreateContainer(ctx context.Context, pod *api.PodSandbox, ctr *api.Container) (*api.ContainerAdjustment, []*api.ContainerUpdate, error) {
    adjust := &api.ContainerAdjustment{}
    devices, found := p.podManager.GetDevicesByPodUID(k8stypes.UID(pod.Uid))
    if !found { return adjust, nil, nil }
    seenPaths := make(map[string]bool)
    for _, device := range devices {
        for _, mount := range device.ContainerEdits.Mounts {
            if seenPaths[mount.ContainerPath] { continue }
            seenPaths[mount.ContainerPath] = true
            adjust.AddMount(&api.Mount{
                Source: mount.HostPath, Destination: mount.ContainerPath,
                Type: "bind", Options: mount.Options,
            })
        }
    }
    return adjust, nil, nil
}
```

**Patch 7: Aggregate metadata per request** (`pkg/devicestate/state.go` + `pkg/nri/nri.go`)

Moved KEP-5304 metadata writing from per-device (`applyConfigOnDevice`) to per-request (`prepareDevices`). When `count: 4` creates 4 devices on the same request name, they all tried to mount at the same path → NRI conflict. Now one metadata file contains all devices for a request, and one mount is created.

### AMD GPU DRA Driver — 2 patches

All in `/home/jhull/devel/amd/k8s-gpu-dra-driver/`.

**Patch 1: Empty driverVersion fallback** (`pkg/amdgpu/amdgpu.go`)

In-kernel `amdgpu` module doesn't set `/sys/module/amdgpu/version`. `GetDriverVersion()` returns empty string which fails K8s ResourceSlice semver validation. Two early-return paths both need the fallback:

```go
func GetDriverVersion() (string, string) {
    matches, _ := filepath.Glob("/sys/class/drm/card*/device/driver/module/version")
    if len(matches) == 0 {
        return "0.0.0", ""  // was ("", "")
    }
    // ... loop ...
    return "0.0.0", ""  // was ("", "")
}
```

**Patch 2: Multi-driver claim filter** (`cmd/gpu-kubeletplugin/state.go`)

`prepareDevices()` iterates all `claim.Status.Allocation.Devices.Results` without checking the driver. On multi-driver claims (GPU + CPU + NIC), it tries to prepare CPU devices as GPUs → error. Fix:

```go
for _, result := range claim.Status.Allocation.Devices.Results {
    if result.Driver != consts.DriverName {
        continue  // skip other drivers' devices
    }
    // ... existing logic
}
```

### KubeVirt — 8 patches

All in `/home/jhull/devel/kubevirt/kubevirt/`.

**Patch 1: Unlimited memlock** (`pkg/hypervisor/kvm/runtime.go`)

VFIO VMs need unlimited memlock for DMA mapping. Set `RLIMIT_MEMLOCK` to `math.MaxInt64`:

```go
if hasVFIODevices {
    rlimits = append(rlimits, &runtimeapi.PosixRlimit{Type: "RLIMIT_MEMLOCK", Hard: math.MaxInt64, Soft: math.MaxInt64})
}
```

**Patch 2: Root mode for hugepages** (`pkg/util/util.go`)

`IsNonRootVMI()` returns false for hugepages VMs, forcing root-mode virt-launcher (needed for `/dev/hugepages` access).

**Patch 3: Additional capabilities** (`pkg/virt-controller/services/rendercontainer.go`)

Root-mode VMs need: `SYS_NICE`, `NET_ADMIN`, `NET_RAW`, `SYS_RESOURCE`, `SYS_RAWIO`, `DAC_OVERRIDE`, `FOWNER`, `SYS_PTRACE`. Also `AllowPrivilegeEscalation=true`.

**Patch 4: Locked schema** (`pkg/virt-launcher/virtwrap/api/schema.go`)

Added `Locked *Locked` field to `MemoryBacking` struct and `type Locked struct{}`.

**Patch 5: Set locked + skip memfd** (`pkg/virt-launcher/virtwrap/converter/converter.go`)

When VFIO devices present: add `<locked/>` to MemoryBacking, skip `memory-backend-memfd` (VFIO DMA mapping fails with memfd).

**Patch 6: Locked conversion** (`pkg/virt-launcher/virtwrap/libvirtxml/convert.go`)

`ConvertKubeVirtMemoryBackingToDomainMemoryBacking`: Locked → DomainMemoryLocked conversion.

**Patch 7: DRA permission skip** (`pkg/virt-controller/services/renderresources.go`)

DRA-provisioned host devices have `ClaimRequest` set but empty `DeviceName`. Skip `permittedHostDevices` check:

```go
if hostDev.ClaimRequest != nil && hostDev.ClaimName != nil {
    continue  // DRA devices don't need permission check
}
```

**Patch 8: dmidecode stub** (virt-launcher image)

Root-mode virt-launcher crashes on `/dev/mem` read. Replace `/usr/sbin/dmidecode` with no-op:

```dockerfile
RUN printf '#!/bin/sh\nexit 0\n' > /usr/sbin/dmidecode && chmod +x /usr/sbin/dmidecode
```

### Topology Coordinator — 1 patch

In `/home/jhull/devel/kubernetes/k8s-dra-topology-coordinator/`.

**Patch 1: pcieRoot excludes non-PCI drivers** (`internal/controller/deviceclass_manager.go`)

`matchAttribute: resource.kubernetes.io/pcieRoot` was added for ALL drivers, but CPU/memory drivers don't publish pcieRoot → claims unsatisfiable. Filter to only PCI-based drivers with non-nil PCIeRoot.

PR: fabiendupont/k8s-dra-topology-coordinator#1

---

## Workarounds (Not Code Patches)

### OpenShift-Specific

| Workaround | Why |
|------------|-----|
| MachineConfig `99-enable-nri` | CRI-O NRI not enabled by default |
| `oc adm policy add-scc-to-user privileged` for each DRA driver SA | OpenShift SCCs block privileged DaemonSets |
| CNI init container skip (SR-IOV) | RHCOS has `/opt/cni` as symlink → init fails |
| CNI bin volume `/var/lib/cni/bin` | RHCOS read-only `/usr` |
| hostNetwork swap (CPU driver off, SR-IOV on) | Port 8080 conflict |
| Namespace SCC UID range annotation | `oc create namespace` missing OpenShift annotations |
| NFD disabled in GPU operator Helm | OpenShift already has NFD |

### KubeVirt VM Configuration

| Workaround | Why |
|------------|-----|
| `kubevirt.io/memfd: "false"` annotation | memfd + VFIO DMA incompatibility |
| `reservedOverhead.addedOverhead: 8Gi` | VFIO BAR page tables need ~1GB per 256GB BAR |
| `guest: >=3Gi` | QEMU BAR placement at 0x400000000000 fails with <3GB RAM |
| `features.acpi: {}` in VM spec | VEP 115 pxb-pcie `_PXM` methods need ACPI enabled |
| cpuset swap script | CPU Manager packs all CPUs on one NUMA node; swap to cross-NUMA before domain creation |
| `resourceClaimName` (not `source.resourceClaimName`) | K8s 1.34 uses flat format, not K8s 1.32 nested |

### SR-IOV DeviceClass Config

| Workaround | Why |
|------------|-----|
| Default `VfConfig` in DeviceClass `spec.config` | `PrepareResources` fails without opaque config; partition claims from webhook don't include driver config |

### NIC VF Persistence

| Workaround | Why |
|------------|-----|
| Recreate VFs after reboot: `echo N > /sys/class/net/<pf>/device/sriov_numvfs` | SR-IOV VF count not persistent across reboots on RHCOS |

---

## Known Bugs Not Yet Fixed

| Component | Bug | Impact |
|-----------|-----|--------|
| Topology Coordinator | `matchAttribute` uses `nodepartition.dra.k8s.io/numaNode` namespace — no device publishes this | Webhook-expanded partition claims unsatisfiable; must use manual claims with `dra.net/numaNode` |
| Topology Coordinator | Profile label exceeds 63 chars with 4+ drivers | DeviceClass creation fails for full 4-driver profile |
| CRI-O | StopPodSandbox panic on empty CNI result | Node CRI-O crash during cleanup of failed SR-IOV pods |
| DRA CPU Driver | No CPU pinning on K8s 1.34 | `DRAConsumableCapacity` needed (K8s 1.36, GA April 22) |
| DRA Memory Driver | PrepareResources fails on K8s 1.34 | `DRAConsumableCapacity` needed for capacity consumption |
| AMD GPU DRA Driver | No VFIO passthrough mode | Can't use GPUs in KubeVirt VMs via DRA |
| AMD GPU DRA Driver | Vendor-specific `pciAddr` not `resource.kubernetes.io/pciBusID` | Blocks KEP-5304 for GPU metadata |

---

## Next Steps

1. **Install Fedora 43 + K8s 1.36** (releases April 22) — eliminates cpuset swap hack, enables CPU pinning + memory capacity via `DRAConsumableCapacity`
2. **Submit patches upstream** — 18 patches across 4 repos
3. **File bugs** — 12 issues across 5 projects
4. **ROCm workload test** — run PyTorch/HIP on GPU pods
5. **GPU VF (SR-IOV) DRA mode** — AMD DRA driver only supports PFs, not GIM VFs

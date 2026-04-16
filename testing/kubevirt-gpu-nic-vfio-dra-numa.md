# KubeVirt GPU + NIC VFIO Passthrough via DRA with Guest NUMA Topology

**Platform:** Fedora 43 + K8s 1.36.0-rc.0 on Dell XE9680 (8x MI300X, ConnectX-6, 2-socket/2-NUMA)
**Date:** 2026-04-15/16
**KubeVirt:** v1.8.1 (patched)

---

## What Was Achieved

A KubeVirt VM running Fedora 43 with:
- 2 MI300X GPU VFs (VFIO passthrough via DRA)
- 2 ConnectX-6 NIC VFs (VFIO passthrough via DRA)
- 8 dedicated vCPUs + 16 GiB hugepages
- Guest sees 2 NUMA nodes with devices on the correct nodes

```
Guest PCI NUMA mapping:
  0000:ff:00.0: numa=0  GPU  (MI300X VF from host NUMA 0)
  0000:fe:00.0: numa=0  NIC  (ConnectX-6 VF from host NUMA 0)
  0000:fc:00.0: numa=1  GPU  (MI300X VF from host NUMA 1)
  0000:fb:00.0: numa=1  NIC  (ConnectX-6 VF from host NUMA 1)
```

---

## Architecture

```
User creates ResourceClaims (1 per driver per NUMA)
    │
    ▼
DRA scheduler allocates devices with per-driver CEL selectors
  gpu: device.attributes["gpu.amd.com"].numaNode == 0
  nic: device.attributes["dra.net"].numaNode == 0
    │
    ▼
DRA drivers PrepareResources:
  GPU driver: unbind VF from amdgpu, bind to vfio-pci
  NIC driver: VFs pre-bound to vfio-pci
  Both write KEP-5304 metadata with pciBusID + numaNode
    │
    ▼
KubeVirt virt-controller:
  Reads DRA claims → creates launcher pod
  Forces root mode + SYS_RESOURCE/IPC_LOCK caps for VFIO
  Sets Unconfined seccomp for host device VMs
  Overrides launcher image to patched version
    │
    ▼
KubeVirt virt-launcher:
  Reads KEP-5304 metadata for each DRA hostDevice
  Gets pciBusID → attaches vfio-pci device to QEMU
  Gets numaNode → creates device-only guest NUMA cells
  Builds pxb-pcie expander buses on correct guest NUMA nodes
    │
    ▼
Guest OS sees correct NUMA topology via ACPI _PXM methods
```

---

## Components and Patches

### GIM (MxGPU-Virtualization) — 2 patches for kernel 6.17

| File | Change |
|------|--------|
| `gim_shim/dcore_drv.c` | `vm_flags_set()` for kernel 6.3+ (read-only `vm_flags`) |
| `dkms/config.h` | Force `HAVE_DCORE_IOVA_VM_CTX_PAGE_ARRAY` + `HAVE_DCORE_IOVA_VM_CTX_VFIO_DEVICE` (autoconf probes outdated for 6.17) |

### AMD GPU DRA Driver — 3 patches

| File | Change |
|------|--------|
| `cmd/gpu-kubeletplugin/state.go` | Call `VfioPciManager.Configure()` for ALL VFIO devices (not just PFs with Parent) |
| `cmd/gpu-kubeletplugin/vfio_manager.go` | Fix `unbindFromDriver` sysfs path — use absolute `/sys/bus/pci/drivers/{name}/unbind` instead of relative readlink |
| `cmd/gpu-kubeletplugin/deviceinfo.go` | Removed `dra.net/numaNode` patch — driver uses its own `numaNode` attribute |

### Topology Coordinator — per-driver CEL selectors

| Branch | Change |
|--------|--------|
| `fix/per-driver-cel-selectors` | Replace cross-driver `matchAttribute` with per-driver CEL selectors from topology rules. Each driver keeps its own NUMA attribute namespace. |
| `test/all-fixes-combined` | All coordinator fixes merged: per-driver CEL, half partitions, proportional partitions, webhook CEL forwarding |

### KubeVirt — 7 patches

| File | Change |
|------|--------|
| `pkg/virt-controller/services/renderresources.go` | Skip `permittedHostDevices` check for DRA devices (`ClaimRequest != nil`) |
| `pkg/virt-controller/services/template.go` | `VIRT_LAUNCHER_IMAGE_OVERRIDE` env var; force root mode for VFIO host devices; `--preserve=mode,timestamps` for container-disk-binary cp |
| `pkg/virt-controller/services/rendercontainer.go` | Add full capabilities (SYS_RESOURCE, IPC_LOCK, CHOWN, etc.) for VFIO host devices |
| `pkg/virt-controller/services/template.go` | Unconfined seccomp for VFIO host device pods |
| `pkg/virt-launcher/virtwrap/converter/converter.go` | `buildDRANUMAOverrides()` reads KEP-5304 numaNode + sysfs fallback; `transformDRAOverridesToGuestCells()` maps host→guest NUMA; reorder to collect NUMA before cell creation |
| `pkg/virt-launcher/virtwrap/converter/vcpu/vcpu.go` | Create device-only guest NUMA cells for host NUMA nodes with DRA devices but no vCPUs |
| `pkg/virt-launcher/virtwrap/api/schema.go` | `NUMACell.CPUs` tag: `omitempty` to allow CPU-less NUMA cells |
| `pkg/dra/utils.go` | `GetNUMANodeForClaim()` reads numaNode from KEP-5304 metadata |

### System Configuration

| Setting | Value | Why |
|---------|-------|-----|
| `containerd LimitMEMLOCK` | `infinity` | VFIO DMA mapping needs unlimited locked memory |
| `SELinux` | Permissive | Root-mode launcher needs file access |
| `kubelet cpuManagerPolicy` | `static` | Required for `dedicatedCpuPlacement` |
| `kubelet topologyManagerPolicy` | `best-effort` | Allows multi-NUMA pods |
| `amdgpu` kernel module | blacklisted | GIM owns GPU PFs; amdgpu binds to VFs only |

---

## VM Specification

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstance
spec:
  domain:
    features:
      acpi: {}
    devices:
      hostDevices:
      - name: gpu0
        claimName: g0        # DRA claim for GPU on NUMA 0
        requestName: gpu
      - name: gpu1
        claimName: g1        # DRA claim for GPU on NUMA 1
        requestName: gpu
      - name: nic0
        claimName: c0        # DRA claim for NIC on NUMA 0
        requestName: nic
      - name: nic1
        claimName: c1        # DRA claim for NIC on NUMA 1
        requestName: nic
    cpu:
      cores: 8
      dedicatedCpuPlacement: true
      numa:
        guestMappingPassthrough: {}
    memory:
      hugepages:
        pageSize: 2Mi
    resources:
      requests: { cpu: "8", memory: 16Gi }
      limits: { cpu: "8", memory: 16Gi }
  resourceClaims:
  - name: g0
    resourceClaimName: gpu-numa0
  - name: g1
    resourceClaimName: gpu-numa1
  - name: c0
    resourceClaimName: nic-numa0
  - name: c1
    resourceClaimName: nic-numa1
```

Each ResourceClaim uses per-driver CEL selectors for NUMA placement:
```yaml
# GPU claim (NUMA 0)
selectors:
- cel:
    expression: 'device.attributes["gpu.amd.com"].type == "vfio"'
- cel:
    expression: 'device.attributes["gpu.amd.com"].numaNode == 0'

# NIC claim (NUMA 0)
selectors:
- cel:
    expression: 'device.attributes["dra.net"].numaNode == 0'
```

---

## Key Design Decisions

### Per-driver CEL selectors (no common NUMA attribute needed)

The topology coordinator generates per-driver CEL selectors from topology rule ConfigMaps. Each driver keeps its own NUMA attribute namespace (`gpu.amd.com/numaNode`, `dra.net/numaNode`, `dra.cpu/numaNodeID`). No `matchAttribute` constraint, no common attribute name.

### Device-only guest NUMA cells

KubeVirt's `guestMappingPassthrough` creates guest NUMA nodes from CPU placement. DRA devices on a NUMA node without vCPUs had no guest cell. The fix creates CPU-less guest NUMA cells (1 hugepage, no vCPUs) for device-only NUMA nodes, with pxb-pcie expander buses for correct guest PCI NUMA.

### KEP-5304 + sysfs fallback for NUMA

GPU DRA driver writes `numaNode` in KEP-5304 metadata. NIC DRA driver only writes `pciBusID`. The virt-launcher reads `numaNode` from metadata first, falls back to host sysfs `/sys/bus/pci/devices/{addr}/numa_node` when not available.

### Separate claims per driver

Due to the kubelet KEP-5304 metadata bug (only one driver's metadata CDI mount per claim), GPU and NIC claims must be separate. Multi-driver claims lose metadata for the second driver.

---

## Issues Found

| # | Component | Issue | Severity |
|---|-----------|-------|----------|
| 1 | GIM | `vfio_pin_pages` + `vm_flags` API changes on kernel 6.17 | Fixed |
| 2 | AMD GPU DRA driver | `unbindFromDriver` uses relative sysfs path — fails in container | Fixed |
| 3 | AMD GPU DRA driver | VF VFIO binding not triggered (only PFs with Parent) | Fixed |
| 4 | KubeVirt | `permittedHostDevices` blocks DRA devices | Fixed |
| 5 | KubeVirt | virt-launcher lacks SYS_RESOURCE/IPC_LOCK for VFIO memlock | Fixed |
| 6 | KubeVirt | Seccomp blocks file capability exec for patched launcher | Fixed (Unconfined) |
| 7 | KubeVirt | Container-disk-binary cp fails with `--preserve=all` as non-root | Fixed |
| 8 | KubeVirt | `guestMappingPassthrough` ignores DRA device NUMA | Fixed (device-only cells) |
| 9 | KubeVirt | NUMATune strict mode fails for device-only cells (cgroup restriction) | Fixed (no MemNode for device cells) |
| 10 | Kubelet | Multi-driver KEP-5304 metadata — only 1 driver's CDI mount per claim | Workaround (separate claims) |
| 11 | SR-IOV DRA driver | No `numaNode` in KEP-5304 metadata | Workaround (sysfs fallback) |

---

## Verification

```bash
# Inside the guest VM:
$ ls /sys/devices/system/node/ | grep node
node0
node1

$ for d in /sys/bus/pci/devices/*/numa_node; do
    dev=$(basename $(dirname $d)); node=$(cat $d)
    class=$(cat /sys/bus/pci/devices/$dev/class 2>/dev/null)
    [ "$node" != "-1" ] && echo "$dev: numa=$node class=$class"
  done
0000:fa:00.0: numa=1 class=0x060400  # PCI bridge (pxb-pcie NUMA 1)
0000:fa:01.0: numa=1 class=0x060400  # root port (NUMA 1)
0000:fb:00.0: numa=1 class=0x020000  # NIC VF (ConnectX-6, NUMA 1)
0000:fc:00.0: numa=1 class=0x120000  # GPU VF (MI300X, NUMA 1)
0000:fd:00.0: numa=0 class=0x060400  # PCI bridge (pxb-pcie NUMA 0)
0000:fd:01.0: numa=0 class=0x060400  # root port (NUMA 0)
0000:fe:00.0: numa=0 class=0x020000  # NIC VF (ConnectX-6, NUMA 0)
0000:ff:00.0: numa=0 class=0x120000  # GPU VF (MI300X, NUMA 0)
```

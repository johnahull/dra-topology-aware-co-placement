# KubeVirt DRA Integration
**Date:** 2026-04-16

> **TL;DR:** GPU + NIC VFIO passthrough to KubeVirt VMs via DRA, with correct guest NUMA topology. KEP-5304 provides device metadata, VEP 115 pxb-pcie places devices on the right guest NUMA node. Requires patches across 7 components.

## Overview

KubeVirt VMs can receive VFIO-passthrough GPU and NIC devices allocated via Kubernetes DRA (Dynamic Resource Allocation). This document consolidates the full integration picture: the architecture from DRA allocation through guest NUMA topology, the KEP-5304 device metadata mechanism that makes it work, the VEP 115 guest NUMA topology gap that limits it, and the test results from running MI300X GPUs and ConnectX-6 NICs inside KubeVirt VMs on K8s 1.36.

The integration chain has been proven end-to-end on a Dell XE9680 (2-socket, 2-NUMA, 8x MI300X, ConnectX-6) with patched KubeVirt v1.8.1, AMD GPU DRA driver, SR-IOV NIC DRA driver, and the topology coordinator. Guest VMs correctly see multi-NUMA topology with devices placed on the correct guest NUMA nodes. However, several upstream gaps remain: VEP 115 does not natively read DRA device NUMA metadata, multi-driver KEP-5304 metadata injection is broken in the kubelet, and DRA devices are invisible to the topology manager.

---

## Architecture

```
User creates ResourceClaims (1 per driver per NUMA)
    |
    v
DRA scheduler allocates devices with per-driver CEL selectors
  gpu: device.attributes["gpu.amd.com"].numaNode == 0
  nic: device.attributes["dra.net"].numaNode == 0
    |
    v
DRA drivers PrepareResources:
  GPU driver: unbind VF from amdgpu, bind to vfio-pci
  NIC driver: VFs pre-bound to vfio-pci
  Both write KEP-5304 metadata with pciBusID + numaNode
    |
    v
KubeVirt virt-controller:
  Reads DRA claims -> creates launcher pod
  Forces root mode + SYS_RESOURCE/IPC_LOCK caps for VFIO
  Sets Unconfined seccomp for host device VMs
  Overrides launcher image to patched version
    |
    v
KubeVirt virt-launcher:
  Reads KEP-5304 metadata for each DRA hostDevice
  Gets pciBusID -> attaches vfio-pci device to QEMU
  Gets numaNode -> creates device-only guest NUMA cells
  Builds pxb-pcie expander buses on correct guest NUMA nodes
    |
    v
Guest OS sees correct NUMA topology via ACPI _PXM methods
```

---

## KEP-5304: Device Metadata for VMs

### What It Is

KEP-5304 defines how DRA drivers communicate device metadata (especially PCI BDF addresses) to pods via JSON files at a standard path:

```
/var/run/dra-device-attributes/<claimName>/<requestName>/<driver>-metadata.json
```

Key attributes for VM passthrough:
- `resource.kubernetes.io/pciBusID` -- PCI Bus Device Function address for passthrough GPUs and NICs
- `mdevUUID` -- UUID for mediated devices (vGPUs)

KEP-5304 is **necessary but not sufficient** for KubeVirt DRA integration. It solves device discovery (how the VM knows which PCI device was allocated), but the full chain also requires:

1. **DRA drivers must implement VFIO passthrough mode** -- binding VFs to `vfio-pci`, managing IOMMU groups, CDI-injecting `/dev/vfio/*`
2. **Drivers must publish BDF using the standard attribute name** -- `resource.kubernetes.io/pciBusID`, not vendor-specific names
3. **Drivers must opt into KEP-5304** -- three code changes: `EnableDeviceMetadata(true)`, populate `Metadata` in `PrepareResourceClaims`, target k8s 1.36+
4. **KubeVirt VEP 115** -- maps device BDF to host NUMA node via sysfs, creates per-NUMA `pxb-pcie` buses in guest domain XML so AI frameworks detect GPU-NIC co-locality
5. **Cross-driver NUMA co-scheduling** -- no mechanism exists to guarantee GPU and NIC land on the same NUMA node before VEP 115 reports their placement in the guest

### Driver Opt-In Status

Drivers MUST publish `resource.kubernetes.io/pciBusID` as a ResourceSlice attribute -- the Kubernetes-standard name. This is a prerequisite for KEP-5304 metadata file generation; the kubelet reads this standard attribute from the ResourceSlice and writes it into the metadata JSON file. Vendor-specific attribute names (e.g., `pciAddr`, `pciBusID` under a driver domain) are **not** picked up by the kubelet and will not appear in KEP-5304 metadata files.

| Driver | VFIO Passthrough | `resource.kubernetes.io/pciBusID` in ResourceSlice | KEP-5304 Opt-In |
|--------|-----------------|---------------------------------------------------|----------------|
| NVIDIA GPU DRA | **Done** | **Yes** (VFIO mode) | In progress (issue #916, v26.4.0) |
| AMD GPU DRA | Not started | **No** -- uses vendor-specific `pciAddr` instead | Not started |
| SR-IOV NIC DRA | Partial | **Yes** | Not started |

### KubeVirt Implementation Status

KubeVirt already has working code for the DRA path:
- **KEP-5304 metadata reader** -- `pkg/dra/utils.go` reads BDF from metadata files
- **DRA HostDevice creation** -- `pkg/virt-launcher/virtwrap/device/hostdevice/dra/generic_hostdev.go` creates PCI passthrough or mediated device based on attributes
- **VEP 115 NUMA placement** -- `pkg/virt-launcher/virtwrap/converter/pci-placement.go` (Alpha, feature gate `PCINUMAAwareTopology`)
- **VM API `claimRequest` fields** -- replaces device plugin's `deviceName` with `{claimName, requestName}`

### Device Discovery Paths

KubeVirt supports three paths for passthrough device PCI address discovery, all converging into `domain.Spec.Devices.HostDevices` before VEP 115 processes them:

| Path | Mechanism | NUMA Support |
|------|-----------|-------------|
| Multus SR-IOV | Network attachment definitions | Works today |
| Device Plugin | `PCI_RESOURCE_*` env vars from `Allocate()` | Works today (NVIDIA GPU, AMD GPU in `gpu-virtualization` branch) |
| DRA (KEP-5304) | JSON metadata files at standard path | Blocked on driver opt-in and k8s 1.36+ |

### Remaining Gap for VMs

VEP 115 faithfully reports device NUMA placement in the guest topology but cannot influence it. If the scheduler places a GPU on NUMA node 0 and a NIC on NUMA node 1, the guest will see split topology and fall back to slower cross-NUMA paths. The cross-driver NUMA co-scheduling problem directly impacts VM workloads.

---

## VEP 115: Guest NUMA Topology Gap

### Summary

KubeVirt's `guestMappingPassthrough` (VEP 115) creates guest NUMA topology based on the kubelet's CPU/memory NUMA assignment from the topology manager. It does NOT consider DRA device NUMA placement from KEP-5304 metadata. This means DRA-provisioned VFIO devices always show `numa_node=-1` in the guest, even when the host-side NUMA placement is correct.

### Problem

When a VM requests DRA host devices from multiple NUMA nodes:

```yaml
resourceClaims:
- name: numa0
  resourceClaimName: gpu-numa0    # GPU on host NUMA 0
- name: numa1
  resourceClaimName: gpu-numa1    # GPU on host NUMA 1
spec:
  domain:
    cpu:
      numa:
        guestMappingPassthrough: {}
    devices:
      hostDevices:
      - name: gpu-numa0
        claimName: numa0
        requestName: gpu
      - name: gpu-numa1
        claimName: numa1
        requestName: gpu
```

**Expected:** Guest sees 2 NUMA nodes. GPU from host NUMA 0 on guest NUMA 0, GPU from host NUMA 1 on guest NUMA 1.

**Actual:** Guest sees 1 NUMA node (determined by kubelet CPU placement). Both GPUs show `numa_node=-1` because only 1 `pxb-pcie` expander bus is created.

### Root Cause

VEP 115's `guestMappingPassthrough` in `pkg/virt-launcher/virtwrap/converter/converter.go` builds the guest NUMA topology from the kubelet's topology manager hints -- specifically from the CPU affinity of the pod's cgroup. It counts how many host NUMA nodes the pod's CPUs span and creates that many guest NUMA nodes.

With DRA, the device NUMA information comes from KEP-5304 metadata (`numaNode` attribute in `/var/run/kubernetes.io/dra-device-attributes/`), NOT from the kubelet's topology manager. The topology manager only handles CPU and memory placement -- DRA devices are invisible to it.

When the pod requests only 8 CPUs on a 128-CPU 2-NUMA machine, the topology manager places all 8 on a single NUMA node. `guestMappingPassthrough` sees 1 NUMA node and creates a 1-NUMA guest, regardless of the DRA devices spanning both host NUMA nodes.

### Proposed Fix

KubeVirt should also read the `numaNode` attribute from KEP-5304 metadata for each DRA host device and use it to:

1. **Determine guest NUMA node count** -- union of CPU NUMA nodes AND DRA device NUMA nodes
2. **Place pxb-pcie expander buses** on the correct guest NUMA node based on the device's `numaNode` from metadata
3. **Attach VFIO devices** to the matching pxb-pcie bus

#### Implementation

In `pkg/virt-launcher/virtwrap/converter/converter.go`, where `guestMappingPassthrough` builds the guest topology:

1. Read KEP-5304 metadata for each DRA host device to get its `numaNode`
2. Build a set of all NUMA nodes from both CPU affinity AND device metadata
3. Create guest NUMA nodes for each unique host NUMA node
4. When placing VFIO devices on pxb-pcie buses, use the device's `numaNode` from metadata instead of defaulting to the CPU's NUMA node

### Key Files

- `pkg/virt-launcher/virtwrap/converter/converter.go` -- guest NUMA topology builder
- `pkg/virt-launcher/virtwrap/device/hostdevice/dra/generic_hostdev.go` -- DRA host device creation
- `pkg/dra/utils.go` -- KEP-5304 metadata reader (already reads `pciBusID`, needs `numaNode`)

### KEP-5304 Metadata Example

```json
{
  "requests": [{
    "name": "gpu",
    "devices": [{
      "driver": "gpu.amd.com",
      "attributes": {
        "numaNode": {"int": 0},
        "resource.kubernetes.io/pciBusID": {"string": "0000:3d:02.0"}
      }
    }]
  }]
}
```

### Tested On

- Dell XE9680 (2-socket, 2 NUMA, 8x MI300X GPUs)
- K8s 1.36.0-rc.0, KubeVirt 1.8.1
- GIM SR-IOV GPU VFs with VFIO passthrough via DRA
- Topology coordinator per-driver CEL selectors for NUMA placement

### Workaround

Request enough CPUs to force the kubelet topology manager to span both NUMA nodes (65+ CPUs on this machine). This makes `guestMappingPassthrough` create 2 guest NUMA nodes. Not practical for small VMs.

### Related

- VEP 115: PCI NUMA-Aware Topology
- KEP-5304: Native Device Metadata API
- KEP-5491: Standard Topology Attributes (proposed `resource.kubernetes.io/numaNode`)

---

## Test Results

### Early VFIO Test (K8s 1.36, GPU + NIC)

**Date:** 2026-04-14
**Platform:** Fedora 43 + K8s 1.36.0-rc.0 + KubeVirt v1.8.1

#### Achievement

KubeVirt VM running with **AMD MI300X GPU** and **ConnectX-6 NIC VF**, both passed through via VFIO, both allocated via DRA with KEP-5304 device metadata.

```
gpu: gpu.amd.com/gpu-206-205  (NUMA 0, bound to vfio-pci by DRA driver)
nic: sriovnetwork.k8snetworkplumbingwg.io/0000-1d-00-2  (NUMA 0, bound to vfio-pci by DRA driver)
```

#### AMD GPU DRA Driver -- VFIO Mode (3 new patches)

| # | File | Change |
|---|------|--------|
| 6 | `api/.../api.go` | Added `Driver` field to `GpuConfig` (`"vfio-pci"` for VFIO mode) |
| 7 | `cmd/gpu-kubeletplugin/state.go` | Added `applyVFIOConfig()`: unbinds from amdgpu, binds to vfio-pci, creates `/dev/vfio/*` CDI devices. Added `bindToVFIO()`, `getIOMMUGroup()` helpers. |
| 8 | `cmd/gpu-kubeletplugin/state.go` + `cdi.go` | VFIO mode skips common CDI device (`/dev/kfd` not available after unbind). Added `GetClaimDevicesVFIO()`. |

Plus: `--cdi-root=/var/run/cdi` flag needed (default `/etc/cdi` doesn't match containerd). Liveness probe disabled (gRPC health check fails, causes constant restarts).

#### VFIO DeviceClass

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: gpu.amd.com-vfio
spec:
  selectors:
  - cel:
      expression: "device.driver == \"gpu.amd.com\""
  config:
  - opaque:
      driver: gpu.amd.com
      parameters:
        apiVersion: gpu.resource.amd.com/v1alpha1
        kind: GpuConfig
        driver: vfio-pci
```

#### KubeVirt Patches on K8s 1.36

| Patch | From OCP | Still needed | Notes |
|-------|----------|-------------|-------|
| DRA permission skip (`renderresources.go`) | #7 | **Yes** | DRA devices have empty DeviceName |
| KEP-5304 metadata path (`utils.go`) | New | **Yes** | K8s 1.36 writes to `/var/run/kubernetes.io/dra-device-attributes/resourceclaims/`, KubeVirt reads from `/var/run/dra-device-attributes/` |
| dmidecode stub | #8 | **Yes** | Root-mode virt-launcher crashes without it |
| Root mode for hugepages | #2 | **No** | Works without it on plain K8s |
| Unlimited memlock | #1 | **Not tested** | Single NIC VF worked without it; MI300X PF (256GB BAR) may need it |
| `<locked/>` in MemoryBacking | #4-6 | **Not tested** | |
| Skip memfd for VFIO | #5 | **Yes** | `kubevirt.io/memfd: "false"` annotation still needed |

#### virt-launcher Image Fix

The stock virt-launcher binary reads KEP-5304 metadata from `/var/run/dra-device-attributes/` but K8s 1.36 writes to `/var/run/kubernetes.io/dra-device-attributes/resourceclaims/`. Instead of rebuilding the binary (needs libvirt-devel), we wrap the binaries with shell scripts that create a symlink at runtime:

```dockerfile
FROM quay.io/kubevirt/virt-launcher:v1.8.1
RUN mv /usr/bin/virt-launcher-monitor /usr/bin/virt-launcher-monitor.orig && \
    mv /usr/bin/virt-launcher /usr/bin/virt-launcher.orig && \
    printf '#!/bin/bash\n\
if [ -d /var/run/kubernetes.io/dra-device-attributes/resourceclaims ] && [ ! -e /var/run/dra-device-attributes ]; then\n\
  ln -sf /var/run/kubernetes.io/dra-device-attributes/resourceclaims /var/run/dra-device-attributes\n\
fi\n\
exec /usr/bin/virt-launcher-monitor.orig "$@"\n' > /usr/bin/virt-launcher-monitor && \
    chmod +x /usr/bin/virt-launcher-monitor && \
    printf '#!/bin/bash\n\
if [ -d /var/run/kubernetes.io/dra-device-attributes/resourceclaims ] && [ ! -e /var/run/dra-device-attributes ]; then\n\
  ln -sf /var/run/kubernetes.io/dra-device-attributes/resourceclaims /var/run/dra-device-attributes\n\
fi\n\
exec /usr/bin/virt-launcher.orig "$@"\n' > /usr/bin/virt-launcher && \
    chmod +x /usr/bin/virt-launcher
RUN printf '#!/bin/sh\nexit 0\n' > /usr/sbin/dmidecode && chmod +x /usr/sbin/dmidecode
```

The virt-operator must be scaled to 0 to prevent image reversion: `kubectl scale deployment virt-operator -n kubevirt --replicas=0`.

#### Issues Found

##### Multi-Driver KEP-5304 Metadata in Single Claim

When a single ResourceClaim contains devices from multiple DRA drivers (e.g., GPU + NIC), the kubelet's native KEP-5304 API only injects the metadata CDI mount for one driver, not all. The second driver's metadata file exists on the host but is not mounted into the container.

**Root cause:** The kubelet plugin framework injects the metadata CDI device ID into the first CDI device per request. When two drivers share a claim, only the first driver's metadata CDI device is resolved by containerd.

**Workaround:** Use **separate ResourceClaims** -- one per driver. Each claim has one driver, so metadata injection works correctly.

**Upstream fix needed:** The kubelet should inject metadata CDI devices for ALL drivers in a multi-driver claim, not just the first.

##### GPU DRA Driver Liveness Probe Failure

The AMD GPU DRA driver's gRPC health check on port 51515 fails intermittently, causing the liveness probe to kill the pod every ~100s. This prevents `PrepareResources` from running.

**Workaround:** Remove the liveness probe from the DaemonSet.

##### GPU Discovery After VFIO Binding

When a GPU is bound to vfio-pci (by a previous claim), it disappears from the driver's discovery (which scans `/sys/module/amdgpu/drivers/`). After unprepare, the GPU is rebound to amdgpu, but the driver needs a restart to re-discover it.

**Impact:** After a VFIO VM is deleted, the GPU is "lost" until the driver pod restarts.

##### CDI Root Path Mismatch

The AMD GPU DRA driver defaults to `--cdi-root=/etc/cdi` but containerd watches `/var/run/cdi`. CDI spec files written to `/etc/cdi` are invisible to containerd.

**Fix:** Pass `--cdi-root=/var/run/cdi` in the DaemonSet args.

##### Note: Physical GPUs (PFs) vs SR-IOV VFs

On this Fedora setup, we're passing entire physical MI300X GPUs (PFs, device ID `74a1`) via VFIO -- not SR-IOV VFs (device ID `74b5`). The GIM driver is not installed. For production:
- Install GIM to create GPU VFs
- Each VF can be passed to a separate VM
- Without GIM: 1 GPU = 1 VM (no sharing)

#### VM Spec (Separate Claims)

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: vm0-gpu
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.amd.com-vfio
        count: 1
        selectors:
        - cel:
            expression: 'device.attributes["gpu.amd.com"].numaNode == 0'
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: vm0-nic
spec:
  devices:
    requests:
    - name: vf
      exactly:
        deviceClassName: sriovnetwork.k8snetworkplumbingwg.io
        count: 1
        selectors:
        - cel:
            expression: 'device.attributes["dra.net"].numaNode == 0'
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm0
spec:
  runStrategy: Always
  template:
    metadata:
      annotations:
        kubevirt.io/memfd: "false"
    spec:
      domain:
        features:
          acpi: {}
        cpu:
          cores: 4
        memory:
          guest: 4Gi
          hugepages:
            pageSize: 2Mi
        devices:
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          hostDevices:
          - claimName: gpu-claim
            name: gpu0
            requestName: gpu
          - claimName: nic-claim
            name: nic0
            requestName: vf
      resourceClaims:
      - name: gpu-claim
        resourceClaimName: vm0-gpu
      - name: nic-claim
        resourceClaimName: vm0-nic
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/containerdisks/fedora:41
```

#### Cumulative AMD GPU DRA Driver Patches (K8s 1.36)

| # | File | Change |
|---|------|--------|
| 1 | `pkg/amdgpu/amdgpu.go` | Fallback `"0.0.0"` when driver version empty |
| 2 | `cmd/gpu-kubeletplugin/state.go` | Multi-driver claim filter (`result.Driver`) |
| 3 | `cmd/gpu-kubeletplugin/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` + populate Metadata |
| 4 | `cmd/gpu-kubeletplugin/deviceinfo.go` | Standard `resource.kubernetes.io/pciBusID` attribute |
| 5 | Various | `CDIDeviceIDs` -> `CdiDeviceIds` for K8s 1.36 |
| 6 | `api/.../api.go` | `Driver` field in `GpuConfig` for VFIO mode |
| 7 | `cmd/gpu-kubeletplugin/state.go` | `applyVFIOConfig()` + `bindToVFIO()` + `getIOMMUGroup()` |
| 8 | `cmd/gpu-kubeletplugin/state.go` + `cdi.go` | VFIO skips common CDI device; `GetClaimDevicesVFIO()` |

---

### Full GPU + NIC VFIO with Guest NUMA

**Date:** 2026-04-15/16
**Platform:** Fedora 43 + K8s 1.36.0-rc.0 on Dell XE9680 (8x MI300X, ConnectX-6, 2-socket/2-NUMA)
**KubeVirt:** v1.8.1 (patched)

#### Achievement

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

#### Components and Patches

##### GIM (MxGPU-Virtualization) -- 2 patches for kernel 6.17

| File | Change |
|------|--------|
| `gim_shim/dcore_drv.c` | `vm_flags_set()` for kernel 6.3+ (read-only `vm_flags`) |
| `dkms/config.h` | Force `HAVE_DCORE_IOVA_VM_CTX_PAGE_ARRAY` + `HAVE_DCORE_IOVA_VM_CTX_VFIO_DEVICE` (autoconf probes outdated for 6.17) |

##### AMD GPU DRA Driver -- 3 patches

| File | Change |
|------|--------|
| `cmd/gpu-kubeletplugin/state.go` | Call `VfioPciManager.Configure()` for ALL VFIO devices (not just PFs with Parent) |
| `cmd/gpu-kubeletplugin/vfio_manager.go` | Fix `unbindFromDriver` sysfs path -- use absolute `/sys/bus/pci/drivers/{name}/unbind` instead of relative readlink |
| `cmd/gpu-kubeletplugin/deviceinfo.go` | Removed `dra.net/numaNode` patch -- driver uses its own `numaNode` attribute |

##### Topology Coordinator -- per-driver CEL selectors

| Branch | Change |
|--------|--------|
| `fix/per-driver-cel-selectors` | Replace cross-driver `matchAttribute` with per-driver CEL selectors from topology rules. Each driver keeps its own NUMA attribute namespace. |
| `test/all-fixes-combined` | All coordinator fixes merged: per-driver CEL, half partitions, proportional partitions, webhook CEL forwarding |

##### KubeVirt -- 7 patches

| File | Change |
|------|--------|
| `pkg/virt-controller/services/renderresources.go` | Skip `permittedHostDevices` check for DRA devices (`ClaimRequest != nil`) |
| `pkg/virt-controller/services/template.go` | `VIRT_LAUNCHER_IMAGE_OVERRIDE` env var; force root mode for VFIO host devices; `--preserve=mode,timestamps` for container-disk-binary cp |
| `pkg/virt-controller/services/rendercontainer.go` | Add full capabilities (SYS_RESOURCE, IPC_LOCK, CHOWN, etc.) for VFIO host devices |
| `pkg/virt-controller/services/template.go` | Unconfined seccomp for VFIO host device pods |
| `pkg/virt-launcher/virtwrap/converter/converter.go` | `buildDRANUMAOverrides()` reads KEP-5304 numaNode + sysfs fallback; `transformDRAOverridesToGuestCells()` maps host->guest NUMA; reorder to collect NUMA before cell creation |
| `pkg/virt-launcher/virtwrap/converter/vcpu/vcpu.go` | Create device-only guest NUMA cells for host NUMA nodes with DRA devices but no vCPUs |
| `pkg/virt-launcher/virtwrap/api/schema.go` | `NUMACell.CPUs` tag: `omitempty` to allow CPU-less NUMA cells |
| `pkg/dra/utils.go` | `GetNUMANodeForClaim()` reads numaNode from KEP-5304 metadata |

##### System Configuration

| Setting | Value | Why |
|---------|-------|-----|
| `containerd LimitMEMLOCK` | `infinity` | VFIO DMA mapping needs unlimited locked memory |
| `SELinux` | Permissive | Root-mode launcher needs file access |
| `kubelet cpuManagerPolicy` | `static` | Required for `dedicatedCpuPlacement` |
| `kubelet topologyManagerPolicy` | `best-effort` | Allows multi-NUMA pods |
| `amdgpu` kernel module | blacklisted | GIM owns GPU PFs; amdgpu binds to VFs only |

#### Key Design Decisions

##### Per-driver CEL selectors (no common NUMA attribute needed)

The topology coordinator generates per-driver CEL selectors from topology rule ConfigMaps. Each driver keeps its own NUMA attribute namespace (`gpu.amd.com/numaNode`, `dra.net/numaNode`, `dra.cpu/numaNodeID`). No `matchAttribute` constraint, no common attribute name.

##### Device-only guest NUMA cells

KubeVirt's `guestMappingPassthrough` creates guest NUMA nodes from CPU placement. DRA devices on a NUMA node without vCPUs had no guest cell. The fix creates CPU-less guest NUMA cells (1 hugepage, no vCPUs) for device-only NUMA nodes, with pxb-pcie expander buses for correct guest PCI NUMA.

##### KEP-5304 + sysfs fallback for NUMA

GPU DRA driver writes `numaNode` in KEP-5304 metadata. NIC DRA driver only writes `pciBusID`. The virt-launcher reads `numaNode` from metadata first, falls back to host sysfs `/sys/bus/pci/devices/{addr}/numa_node` when not available.

##### Separate claims per driver

Due to the kubelet KEP-5304 metadata bug (only one driver's metadata CDI mount per claim), GPU and NIC claims must be separate. Multi-driver claims lose metadata for the second driver.

#### VM Specification

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

#### Issues Found

| # | Component | Issue | Severity |
|---|-----------|-------|----------|
| 1 | GIM | `vfio_pin_pages` + `vm_flags` API changes on kernel 6.17 | Fixed |
| 2 | AMD GPU DRA driver | `unbindFromDriver` uses relative sysfs path -- fails in container | Fixed |
| 3 | AMD GPU DRA driver | VF VFIO binding not triggered (only PFs with Parent) | Fixed |
| 4 | KubeVirt | `permittedHostDevices` blocks DRA devices | Fixed |
| 5 | KubeVirt | virt-launcher lacks SYS_RESOURCE/IPC_LOCK for VFIO memlock | Fixed |
| 6 | KubeVirt | Seccomp blocks file capability exec for patched launcher | Fixed (Unconfined) |
| 7 | KubeVirt | Container-disk-binary cp fails with `--preserve=all` as non-root | Fixed |
| 8 | KubeVirt | `guestMappingPassthrough` ignores DRA device NUMA | Fixed (device-only cells) |
| 9 | KubeVirt | NUMATune strict mode fails for device-only cells (cgroup restriction) | Fixed (no MemNode for device cells) |
| 10 | Kubelet | Multi-driver KEP-5304 metadata -- only 1 driver's CDI mount per claim | Workaround (separate claims) |
| 11 | SR-IOV DRA driver | No `numaNode` in KEP-5304 metadata | Workaround (sysfs fallback) |

#### Verification

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

---

## Required Patches

Consolidated table of ALL patches from both test rounds, by component.

| Component | File / Area | Change | Test Round |
|-----------|-------------|--------|------------|
| **GIM** | `gim_shim/dcore_drv.c` | `vm_flags_set()` for kernel 6.3+ | Full GPU+NIC NUMA |
| **GIM** | `dkms/config.h` | Force `HAVE_DCORE_IOVA_VM_CTX_PAGE_ARRAY` + `HAVE_DCORE_IOVA_VM_CTX_VFIO_DEVICE` | Full GPU+NIC NUMA |
| **AMD GPU DRA** | `pkg/amdgpu/amdgpu.go` | Fallback `"0.0.0"` when driver version empty | Early VFIO |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/state.go` | Multi-driver claim filter (`result.Driver`) | Early VFIO |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/driver.go` | `EnableDeviceMetadata(true)` + `MetadataVersions` + populate Metadata | Early VFIO |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/deviceinfo.go` | Standard `resource.kubernetes.io/pciBusID` attribute | Early VFIO |
| **AMD GPU DRA** | Various | `CDIDeviceIDs` -> `CdiDeviceIds` for K8s 1.36 | Early VFIO |
| **AMD GPU DRA** | `api/.../api.go` | `Driver` field in `GpuConfig` for VFIO mode | Early VFIO |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/state.go` | `applyVFIOConfig()` + `bindToVFIO()` + `getIOMMUGroup()` | Early VFIO |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/state.go` + `cdi.go` | VFIO skips common CDI device; `GetClaimDevicesVFIO()` | Early VFIO |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/state.go` | Call `VfioPciManager.Configure()` for ALL VFIO devices (not just PFs with Parent) | Full GPU+NIC NUMA |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/vfio_manager.go` | Fix `unbindFromDriver` sysfs path -- absolute `/sys/bus/pci/drivers/{name}/unbind` | Full GPU+NIC NUMA |
| **AMD GPU DRA** | `cmd/gpu-kubeletplugin/deviceinfo.go` | Removed `dra.net/numaNode` patch -- driver uses its own `numaNode` attribute | Full GPU+NIC NUMA |
| **Topology Coordinator** | `fix/per-driver-cel-selectors` | Per-driver CEL selectors from topology rules | Full GPU+NIC NUMA |
| **Topology Coordinator** | `test/all-fixes-combined` | All coordinator fixes merged | Full GPU+NIC NUMA |
| **KubeVirt** | `pkg/virt-controller/services/renderresources.go` | Skip `permittedHostDevices` check for DRA devices | Both |
| **KubeVirt** | `pkg/dra/utils.go` | KEP-5304 metadata path fix (symlink workaround) | Early VFIO |
| **KubeVirt** | `pkg/dra/utils.go` | `GetNUMANodeForClaim()` reads numaNode from KEP-5304 metadata | Full GPU+NIC NUMA |
| **KubeVirt** | virt-launcher image | dmidecode stub for root-mode launcher | Both |
| **KubeVirt** | virt-launcher image | Wrapper scripts for KEP-5304 metadata path symlink | Early VFIO |
| **KubeVirt** | `pkg/virt-controller/services/template.go` | `VIRT_LAUNCHER_IMAGE_OVERRIDE` env var; force root mode; `--preserve=mode,timestamps` | Full GPU+NIC NUMA |
| **KubeVirt** | `pkg/virt-controller/services/rendercontainer.go` | Full capabilities (SYS_RESOURCE, IPC_LOCK, CHOWN, etc.) for VFIO | Full GPU+NIC NUMA |
| **KubeVirt** | `pkg/virt-controller/services/template.go` | Unconfined seccomp for VFIO host device pods | Full GPU+NIC NUMA |
| **KubeVirt** | `pkg/virt-launcher/virtwrap/converter/converter.go` | `buildDRANUMAOverrides()` + `transformDRAOverridesToGuestCells()` | Full GPU+NIC NUMA |
| **KubeVirt** | `pkg/virt-launcher/virtwrap/converter/vcpu/vcpu.go` | Device-only guest NUMA cells | Full GPU+NIC NUMA |
| **KubeVirt** | `pkg/virt-launcher/virtwrap/api/schema.go` | `NUMACell.CPUs` `omitempty` for CPU-less cells | Full GPU+NIC NUMA |

---

## Remaining Gaps

1. **VEP 115 does not read DRA device NUMA metadata.** Upstream KubeVirt's `guestMappingPassthrough` builds guest NUMA topology solely from CPU cgroup affinity. DRA devices are invisible. Our patches add `buildDRANUMAOverrides()` and device-only NUMA cells, but this needs to land upstream in KubeVirt for the integration to work without local patches.

2. **Multi-driver KEP-5304 metadata injection is broken in the kubelet.** When a single ResourceClaim contains devices from multiple DRA drivers, the kubelet only injects the metadata CDI mount for one driver. The workaround (separate claims per driver) is functional but adds manifest complexity and prevents single-claim multi-device co-scheduling constraints. An upstream kubelet fix is needed.

3. **DRA devices are invisible to the topology manager.** The kubelet topology manager handles CPU and memory NUMA placement but has no awareness of DRA-allocated devices. This means the topology manager cannot co-place CPUs with DRA devices on the same NUMA node. The topology coordinator fills this gap at the scheduling layer with per-driver CEL selectors, but the kubelet itself cannot enforce NUMA alignment between CPUs/memory and DRA devices at the node level.

---

## References

- VEP 115: PCI NUMA-Aware Topology
- KEP-5304: Native Device Metadata API
- KEP-5491: Standard Topology Attributes (proposed `resource.kubernetes.io/numaNode`)
- KEP-4381: DRA Structured Parameters (`resource.kubernetes.io/pciBusID`)
- [Early VFIO test results](../testing/kubevirt-gpu-vfio-results.md)
- [Full GPU + NIC VFIO with guest NUMA results](../testing/kubevirt-gpu-nic-vfio-dra-numa.md)
- [VEP 115 guest NUMA topology gap analysis](../testing/kubevirt-vep115-dra-numa-gap.md)

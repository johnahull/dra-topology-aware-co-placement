# KubeVirt VM with GPU + NIC VFIO via DRA — K8s 1.36

**Date:** 2026-04-14
**Platform:** Fedora 43 + K8s 1.36.0-rc.0 + KubeVirt v1.8.1

---

## Achievement

KubeVirt VM running with **AMD MI300X GPU** and **ConnectX-6 NIC VF**, both passed through via VFIO, both allocated via DRA with KEP-5304 device metadata.

```
gpu: gpu.amd.com/gpu-206-205  (NUMA 0, bound to vfio-pci by DRA driver)
nic: sriovnetwork.k8snetworkplumbingwg.io/0000-1d-00-2  (NUMA 0, bound to vfio-pci by DRA driver)
```

---

## Patches Applied

### AMD GPU DRA Driver — VFIO Mode (3 new patches)

| # | File | Change |
|---|------|--------|
| 6 | `api/.../api.go` | Added `Driver` field to `GpuConfig` (`"vfio-pci"` for VFIO mode) |
| 7 | `cmd/gpu-kubeletplugin/state.go` | Added `applyVFIOConfig()`: unbinds from amdgpu, binds to vfio-pci, creates `/dev/vfio/*` CDI devices. Added `bindToVFIO()`, `getIOMMUGroup()` helpers. |
| 8 | `cmd/gpu-kubeletplugin/state.go` + `cdi.go` | VFIO mode skips common CDI device (`/dev/kfd` not available after unbind). Added `GetClaimDevicesVFIO()`. |

Plus: `--cdi-root=/var/run/cdi` flag needed (default `/etc/cdi` doesn't match containerd). Liveness probe disabled (gRPC health check fails, causes constant restarts).

### VFIO DeviceClass

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

### KubeVirt Patches on K8s 1.36

| Patch | From OCP | Still needed | Notes |
|-------|----------|-------------|-------|
| DRA permission skip (`renderresources.go`) | #7 | **Yes** | DRA devices have empty DeviceName |
| KEP-5304 metadata path (`utils.go`) | New | **Yes** | K8s 1.36 writes to `/var/run/kubernetes.io/dra-device-attributes/resourceclaims/`, KubeVirt reads from `/var/run/dra-device-attributes/` |
| dmidecode stub | #8 | **Yes** | Root-mode virt-launcher crashes without it |
| Root mode for hugepages | #2 | **No** | Works without it on plain K8s |
| Unlimited memlock | #1 | **Not tested** | Single NIC VF worked without it; MI300X PF (256GB BAR) may need it |
| `<locked/>` in MemoryBacking | #4-6 | **Not tested** | |
| Skip memfd for VFIO | #5 | **Yes** | `kubevirt.io/memfd: "false"` annotation still needed |

### virt-launcher Image Fix

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

---

## Issues Found

### Multi-Driver KEP-5304 Metadata in Single Claim

When a single ResourceClaim contains devices from multiple DRA drivers (e.g., GPU + NIC), the kubelet's native KEP-5304 API only injects the metadata CDI mount for one driver, not all. The second driver's metadata file exists on the host but is not mounted into the container.

**Root cause:** The kubelet plugin framework injects the metadata CDI device ID into the first CDI device per request. When two drivers share a claim, only the first driver's metadata CDI device is resolved by containerd.

**Workaround:** Use **separate ResourceClaims** — one per driver. Each claim has one driver, so metadata injection works correctly.

**Upstream fix needed:** The kubelet should inject metadata CDI devices for ALL drivers in a multi-driver claim, not just the first.

### GPU DRA Driver Liveness Probe Failure

The AMD GPU DRA driver's gRPC health check on port 51515 fails intermittently, causing the liveness probe to kill the pod every ~100s. This prevents `PrepareResources` from running.

**Workaround:** Remove the liveness probe from the DaemonSet.

### GPU Discovery After VFIO Binding

When a GPU is bound to vfio-pci (by a previous claim), it disappears from the driver's discovery (which scans `/sys/module/amdgpu/drivers/`). After unprepare, the GPU is rebound to amdgpu, but the driver needs a restart to re-discover it.

**Impact:** After a VFIO VM is deleted, the GPU is "lost" until the driver pod restarts.

### CDI Root Path Mismatch

The AMD GPU DRA driver defaults to `--cdi-root=/etc/cdi` but containerd watches `/var/run/cdi`. CDI spec files written to `/etc/cdi` are invisible to containerd.

**Fix:** Pass `--cdi-root=/var/run/cdi` in the DaemonSet args.

### Note: Physical GPUs (PFs) vs SR-IOV VFs

On this Fedora setup, we're passing entire physical MI300X GPUs (PFs, device ID `74a1`) via VFIO — not SR-IOV VFs (device ID `74b5`). The GIM driver is not installed. For production:
- Install GIM to create GPU VFs
- Each VF can be passed to a separate VM
- Without GIM: 1 GPU = 1 VM (no sharing)

---

## VM Spec (Separate Claims)

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

---

## Cumulative AMD GPU DRA Driver Patches (K8s 1.36)

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

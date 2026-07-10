# XE9680 MI300X GIM VF Passthrough Session — 2026-06-02

## Result

**Multi-NUMA GPU VF passthrough with correct topology in a KubeVirt VM — working.**

### 2-NUMA VM (final)

Topology coordinator allocates an eighth partition from NUMA 0 and NUMA 2, each with
GPU VF + 2 NIC VFs + 16 CPUs + memory. KubeVirt builds 2 guest NUMA nodes with GPUs
on pxb-pcie expander buses showing correct NUMA affinity.

Guest output (`hw-topology.sh -t`):
```
NUMA Topology  (2 socket(s), 2 node(s), SNC off)

╔══ Socket 0 ══╗
║ NUMA 0  (8 GB)
║   pcieRoot: 0000:fe  (dist: 0=10, 1=20)
║     accel: 0000:ff:00.0 (0x1002:0x74b5)
╚════════════════════╝

╔══ Socket 1 ══╗
║ NUMA 1  (8 GB)
║   pcieRoot: 0000:fc  (dist: 0=20, 1=10)
║     accel: 0000:fd:00.0 (0x1002:0x74b5)
╚════════════════════╝
```

2 MI300X VFs on separate pxb-pcie expander buses, each with correct NUMA affinity
and SLIT distances (10 local, 20 remote). 8 CPUs (4 per NUMA), 16GB hugepage memory.

### 1-NUMA VM (earlier)

```
GPU: 0000:ff:00.0 device=0x74b5 numa=0
```

MI300X VF on pxb-pcie expander bus with NUMA 0 affinity, 4 CPUs, 8GB hugepage memory.

### What's not working yet

**NIC VF hostDevices in VM**: The topology coordinator's eighth partition allocates 2
NIC VFs per NUMA node (`count: 2`), but KubeVirt's `resolveDevice()` in
`pkg/dra/utils.go:132` requires exactly 1 device per request name. A patch for
multi-device DRA requests exists (see `kubevirt-multi-device-dra-requests.md`) but
hasn't been applied to the current `feature/dra-all-patches` branch yet.

**NVMe passthrough**: The NVMe DRA driver image (`dra-nvme-driver:numanode-list`) has
an image pull error (401 unauthorized from ghcr.io). NVMe devices exist on NUMA 0 and
1 but aren't exposed via DRA.

## System

- **Host:** j42-h01-000-xe9680.rdu3.labs.perfscale.redhat.com (10.6.62.52)
- **OS:** Fedora 44, kernel 7.0.10-201.fc44.x86_64
- **K8s:** v1.36.1 (kubeadm, single node)
- **Container runtime:** containerd 2.2.3
- **KubeVirt:** built from main + feature/dra-all-patches (9 patches + session fixes)
- **Hardware:** Dell XE9680, 8x MI300X OAM, 4 NUMA nodes, Intel Xeon w/ SNC-2

## Key Finding: PF vs VF Passthrough

**PF passthrough does NOT work on MI300X.** The PCI config space becomes permanently
unreadable (all 0xFF) after a VFIO device reset. The device cannot be recovered without
a full host reboot. This is an MI300X firmware issue.

**VF passthrough via GIM works.** The GIM (GPU-IOV Module) driver creates SR-IOV VFs
that bind cleanly to vfio-pci and pass through to VMs without config space corruption.

## Setup Steps

### 1. Build GIM for the Running Kernel

GIM source: `github.com/amd/MxGPU-Virtualization`, branch `release/9.0.x.K-rc`

```bash
# Install build deps
dnf install -y kernel-devel-$(uname -r) autoconf automake make gcc

# Clone and build
cd /tmp/MxGPU-Virtualization/gim

# Run configure (generates config.h with feature detection)
make  # will fail but generates dkms/config.h

# Fix config.h for kernel 7.0+ (configure tests fail on newer kernels)
sed -i \
  -e 's|/\* #undef HAVE_LOFF_T_VARIABLE \*/|#define HAVE_LOFF_T_VARIABLE 1|' \
  -e 's|/\* #undef HAVE_VPRINTK_EMIT_5_ARG \*/|#define HAVE_VPRINTK_EMIT_5_ARG 1|' \
  -e 's|/\* #undef HAVE_PCI_ALLOC_IRQ_VECTORS \*/|#define HAVE_PCI_ALLOC_IRQ_VECTORS 1|' \
  -e 's|/\* #undef HAVE_HRTIMER_SETUP \*/|#define HAVE_HRTIMER_SETUP 1|' \
  -e 's|/\* #undef HAVE_BRIDGE_SECONDARY_BUS_RESET \*/|#define HAVE_BRIDGE_SECONDARY_BUS_RESET 1|' \
  -e 's|/\* #undef VFS_UNLINK_HAS_IDMAP_ARG \*/|#define VFS_UNLINK_HAS_IDMAP_ARG 1|' \
  -e 's|/\* #undef HAVE_FTRACE_REGS_OPS \*/|#define HAVE_FTRACE_REGS_OPS 1|' \
  -e 's|/\* #undef HAVE_KFREE_SENSITIVE \*/|#define HAVE_KFREE_SENSITIVE 1|' \
  -e 's|/\* #undef HAVE_MAX_PAGE_ORDER \*/|#define HAVE_MAX_PAGE_ORDER 1|' \
  -e 's|/\* #undef HAVE_CLASS_CREATE_1_ARG \*/|#define HAVE_CLASS_CREATE_1_ARG 1|' \
  -e 's|/\* #undef HAVE_DEVNODE_CONST \*/|#define HAVE_DEVNODE_CONST 1|' \
  -e 's|/\* #undef HAVE_DCORE_IOVA_VM_CTX_VFIO_DEVICE \*/|#define HAVE_DCORE_IOVA_VM_CTX_VFIO_DEVICE 1|' \
  -e 's|/\* #undef HAVE_DCORE_IOVA_VM_CTX_PAGE_ARRAY \*/|#define HAVE_DCORE_IOVA_VM_CTX_PAGE_ARRAY 1|' \
  -e 's|/\* #undef HAVE_POLL_T \*/|#define HAVE_POLL_T 1|' \
  -e 's|/\* #undef HAVE_UP_DOWN_READ_MMAP_LOCK_ARG \*/|#define HAVE_UP_DOWN_READ_MMAP_LOCK_ARG 1|' \
  -e 's|/\* #undef HAVE_GET_USER_PAGES_REMOTE_6_ARG \*/|#define HAVE_GET_USER_PAGES_REMOTE_6_ARG 1|' \
  -e 's|/\* #undef HAVE_RTC_KTIME_TO_TM \*/|#define HAVE_RTC_KTIME_TO_TM 1|' \
  dkms/config.h

# Build
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules

# Install
mkdir -p /lib/modules/$(uname -r)/extra
cp gim.ko /lib/modules/$(uname -r)/extra/
depmod -a
```

### 2. Boot Configuration

```bash
# Blacklist amdgpu so GIM gets all GPUs
echo 'blacklist amdgpu' > /etc/modprobe.d/blacklist-amdgpu.conf

# Claim VF device ID for vfio-pci at boot
echo 'options vfio-pci ids=1002:74b5' > /etc/modprobe.d/vfio-gpu-vf.conf

# Load modules at boot
echo -e 'vfio-pci\nvfio_iommu_type1\ngim' > /etc/modules-load.d/gpu-vfio.conf

# IOMMU and hugepages
grubby --update-kernel=ALL --args='intel_iommu=on iommu=pt hugepagesz=1G hugepages=48'

# Regenerate initramfs
dracut --force

reboot
```

### 3. Post-Boot Verification

After reboot:
```bash
# GIM probed all 8 GPUs
dmesg | grep 'AMD GIM probed'  # should show 8

# 8 VFs created and bound to vfio-pci
lspci -d 1002:74b5  # 8 MI300X VF devices
for vf in $(lspci -D -d 1002:74b5 | awk '{print $1}'); do
  readlink -f /sys/bus/pci/devices/$vf/driver | awk -F/ '{print $NF}'
done  # all show vfio-pci

# VFIO device files
ls /dev/vfio/  # 8 IOMMU group numbers + vfio

# Hugepages (allocate per-NUMA)
for n in 0 1 2 3; do
  echo 12 > /sys/devices/system/node/node$n/hugepages/hugepages-1048576kB/nr_hugepages
done
```

### 4. Kubernetes Setup

```bash
# kubelet config: enable CPU manager
# Add to /var/lib/kubelet/config.yaml:
#   cpuManagerPolicy: static
#   topologyManagerPolicy: single-numa-node
#   reservedSystemCPUs: "0-1"
rm -f /var/lib/kubelet/cpu_manager_state
systemctl restart kubelet

# Set cpumanager label
kubectl label node <node> cpumanager=true kubevirt.io/cpumanager=true --overwrite
```

### 5. DRA Driver

The GPU DRA driver's init container waits for `/sys/class/kfd` which doesn't exist
when amdgpu is blacklisted. Patch the daemonset:

```bash
kubectl patch daemonset gpu-dra-driver-k8s-gpu-dra-driver-kubeletplugin -n kube-amd-gpu \
  --type json -p '[{"op":"replace","path":"/spec/template/spec/initContainers/0/command","value":["sh","-c","echo ready"]}]'
```

The DRA driver discovers GIM VFs automatically via `GetVFMapping()`.
Helm value `kubeletPlugin.enablePfPassthrough=true` is NOT needed for VFs.

### 6. KubeVirt Feature Gates

```yaml
spec:
  configuration:
    developerConfiguration:
      featureGates:
      - GPUsWithDRA
      - HostDevicesWithDRA
      - HostDevices
      - ReservedOverheadMemlock
      - Root
```

### 7. KubeVirt Code Changes (session fixes)

These changes are needed in addition to the `feature/dra-all-patches` branch:

1. **`<locked/>`** in `MemoryBacking` for VFIO VMs (`converter.go`)
2. **`x-pci-hole64-size=274877906944`** QEMU arg for large BAR GPUs (`converter.go`)
3. **`Locked` struct** added to `MemoryBacking` (`api/schema.go`)
4. **DRA override fallback** in `pci-placement.go` — use `devicesNUMANodes` override when sysfs has no NUMA info
5. **`CAP_SYS_RESOURCE` + root mode** for VFIO VMIs (cherry-pick `80454b63c9`)

### 8. VM Manifest

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: vm-gpu-numa0
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.amd.com
        selectors:
        - cel:
            expression: 'device.attributes["gpu.amd.com"].type == "vfio"'
        - cel:
            expression: 'device.attributes["resource.kubernetes.io"].pciBusID == "0000:1b:02.0"'
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: vm-cpu-numa0
spec:
  devices:
    requests:
    - name: cpu
      exactly:
        deviceClassName: dra.cpu
        selectors:
        - cel:
            expression: 'device.attributes["resource.kubernetes.io"].numaNode.includes(0)'
        capacity:
          requests:
            dra.cpu/cpu: "4"
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: vm-memory-numa0
spec:
  devices:
    requests:
    - name: memory
      exactly:
        deviceClassName: dra.memory
        selectors:
        - cel:
            expression: 'device.attributes["resource.kubernetes.io"].numaNode.includes(0)'
        capacity:
          requests:
            size: 8Gi
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-numa0
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 4
          sockets: 1
          threads: 1
          dedicatedCpuPlacement: true
          numa:
            guestMappingPassthrough: {}
        memory:
          guest: 8Gi
          hugepages:
            pageSize: 1Gi
          reservedOverhead:
            addedOverhead: 4Gi
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
          gpus:
          - name: gpu0
            claimName: gpu-claim
            requestName: gpu
          interfaces:
          - name: default
            masquerade: {}
          rng: {}
        machine:
          type: q35
      networks:
      - name: default
        pod: {}
      resourceClaims:
      - name: gpu-claim
        resourceClaimName: vm-gpu-numa0
      - name: cpu-claim
        resourceClaimName: vm-cpu-numa0
      - name: mem-claim
        resourceClaimName: vm-memory-numa0
      tolerations:
      - operator: Exists
      terminationGracePeriodSeconds: 0
      volumes:
      - containerDisk:
          image: quay.io/containerdisks/fedora:41
          imagePullPolicy: IfNotPresent
        name: containerdisk
      - cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd:
              expire: false
            ssh_pwauth: true
        name: cloudinitdisk
```

### 9. 2-NUMA VM with Topology Coordinator

Use the topology coordinator's eighth partition device classes. Each partition
gives GPU + 2 NICs + CPU + memory on one NUMA node. The webhook expands a single
`partition` request into sub-requests (partition-gpu-amd-com, partition-dra-cpu, etc.).

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: vm-eighth-a
spec:
  devices:
    requests:
    - name: partition
      exactly:
        deviceClassName: dra-cpu-dra-memory-gpu-amd-com-sriovnetwork-k8s-bbbe6cc4-eighth-numa0
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: vm-eighth-b
spec:
  devices:
    requests:
    - name: partition
      exactly:
        deviceClassName: dra-cpu-dra-memory-gpu-amd-com-sriovnetwork-k8s-bbbe6cc4-eighth-numa2
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-2numa
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 4
          sockets: 2
          threads: 1
          dedicatedCpuPlacement: true
          numa:
            guestMappingPassthrough: {}
        memory:
          guest: 16Gi
          hugepages:
            pageSize: 1Gi
          reservedOverhead:
            addedOverhead: 4Gi
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
          gpus:
          - name: gpu0
            claimName: eighth-a
            requestName: partition-gpu-amd-com
          - name: gpu1
            claimName: eighth-b
            requestName: partition-gpu-amd-com
          # NIC hostDevices blocked by count>1 limitation (see below)
          interfaces:
          - name: default
            masquerade: {}
          rng: {}
        machine:
          type: q35
      networks:
      - name: default
        pod: {}
      resourceClaims:
      - name: eighth-a
        resourceClaimName: vm-eighth-a
      - name: eighth-b
        resourceClaimName: vm-eighth-b
      tolerations:
      - operator: Exists
      terminationGracePeriodSeconds: 0
      volumes:
      - containerDisk:
          image: quay.io/containerdisks/fedora:41
          imagePullPolicy: IfNotPresent
        name: containerdisk
      - cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd:
              expire: false
            ssh_pwauth: true
        name: cloudinitdisk
```

## Gotchas

1. **numaNode list and `includes()` CEL**: `includes(0)` matches ANY device that has 0
   in its numaNode list — including NUMA 1 GPUs with equidistant peer 0. Use `pciBusID`
   selector for exact device targeting until a "first element" CEL function exists.

2. **Hugepages must be allocated on ALL NUMA nodes** (or at least the ones where VMs
   might land). The DRA GPU claim may pick a GPU on a different NUMA node than expected.

3. **GIM must load BEFORE amdgpu**. Blacklist amdgpu and load GIM via modules-load.d.
   If amdgpu initializes PFs first, GIM's PSP init fails with timeout.

4. **VF config space reads 0xFFFF for vendor:device**. This is normal for GIM VFs —
   the actual device ID is in the subsystem fields. vfio-pci binds via `driver_override`
   or `ids=` module parameter, not PCI ID matching.

5. **`set_mempolicy: Invalid argument`** occurs when the container's cgroup doesn't
   include the target NUMA node. Requires `cpuManagerPolicy: static` with
   `dedicatedCpuPlacement: true` so the container gets a NUMA-aligned cpuset.

6. **pxb-pcie placement needs DRA overrides fallback**. The standard
   `LookupDevicesNumaNodes` can't find NUMA for VFs bound to vfio-pci. The
   `PlacePCIDevicesWithNUMAAlignment` function must check the DRA NUMA overrides
   map when sysfs has no info.

7. **NIC VF hostDevices with count>1**: The topology coordinator's eighth partition
   allocates 2 NIC VFs per NUMA node. KubeVirt's `resolveDevice()` in
   `pkg/dra/utils.go:132` requires exactly 1 device per DRA request name. A patch
   for multi-device DRA requests is documented in
   `docs/upstream-proposals/kubevirt-multi-device-dra-requests.md` but needs to be
   applied to `feature/dra-all-patches`. Workaround: either change the partition
   config to 1 NIC, or apply the multi-device patch.

8. **SR-IOV DRA driver RDMA skip for vfio-pci**: When binding NIC VFs to vfio-pci
   via `VfConfig.driver: vfio-pci`, the driver tries to set up RDMA devices which
   don't exist after the vfio-pci bind. Fixed by skipping RDMA when
   `config.Driver == "vfio-pci"` in `pkg/devicestate/state.go:321`.

9. **`matchAttribute` with list-type attributes**: `matchAttribute:
   resource.kubernetes.io/numaNode` doesn't work with `IntValues` (list) attributes
   even with `DRAListTypeAttributes` enabled. The scheduler can't intersect lists
   across drivers. Use the scalar `dra.net/numaNode` compat attribute instead.
   GPU driver needs to publish `dra.net/numaNode` alongside the list attribute.

10. **PF passthrough does NOT work on MI300X**. The PCI config space becomes all 0xFF
    after VFIO device reset and never recovers without a full host reboot. Only VF
    passthrough via GIM works. See `xe9680-mi300x-vfio-session-2026-06-01.md` for details.

11. **NIC hostDevices show `numa=-1` in guest**. `buildDRANUMAOverrides` in
    `converter.go` only iterates `vmi.Spec.Domain.Devices.GPUs`, not
    `vmi.Spec.Domain.Devices.HostDevices`. NIC VFs passed through as hostDevices
    don't get DRA NUMA overrides, so `PlacePCIDevicesWithNUMAAlignment` can't place
    them on pxb-pcie buses with NUMA affinity.

12. **SR-IOV driver intermittent claim status timeout**. `Failed to update claim
    status after retries: timed out waiting for the condition`. The driver prepares
    devices (binds to vfio-pci) but the K8s API status update times out, triggering
    rollback that restores the original driver. Works on retry. May be related to
    webhook load or API server responsiveness.

13. **SR-IOV VfConfig goes on DeviceClass, not claims**. The `driver: vfio-pci`
    config must be patched onto the `sriovnetwork.k8snetworkplumbingwg.io` DeviceClass
    (not individual claims) so the topology coordinator's expanded sub-requests
    inherit it. See `testing/manifests/coordinator/sriov-resource-policy.yaml`.

## Issues to File

### Kubernetes upstream

1. **`matchAttribute` fails with list-type attributes** — `matchAttribute:
   resource.kubernetes.io/numaNode` with `IntValues` doesn't use set intersection
   despite `DRAListTypeAttributes=true`. Works with scalar `dra.net/numaNode`.
   File against `sig-node/DRA` or `k/k` scheduler.

### KubeVirt upstream

2. **`buildDRANUMAOverrides` should handle hostDevices** — Currently only iterates
   GPUs. HostDevices (NICs) with DRA claims also need NUMA overrides for pxb-pcie
   placement. File against KubeVirt `sig-compute`.

3. **`<locked/>` and `x-pci-hole64-size` for VFIO VMs** — These should be standard
   for any VM with PCI passthrough devices, not just our patches. The `<locked/>`
   enables `mem-lock=on` for DMA; `x-pci-hole64-size` handles GPUs with large BARs
   (MI300X has 262GB). File as enhancement.

4. **Multi-device DRA request support** — `resolveDevice()` requires exactly 1 device
   per request. The multi-device patch (Option B from
   `kubevirt-multi-device-dra-requests.md`) was applied in this session. Needs formal
   PR. File against KubeVirt `sig-compute`.

### AMD GIM

5. **GIM configure tests fail on kernel 6.19+/7.0+** — 17 kernel API changes require
   manual `config.h` fixups. The autoconf tests use `AC_KERNEL_TRY_COMPILE` which
   silently fails on newer kernels. Affects: `HAVE_LOFF_T_VARIABLE`,
   `HAVE_VPRINTK_EMIT_5_ARG`, `HAVE_PCI_ALLOC_IRQ_VECTORS`, `HAVE_HRTIMER_SETUP`,
   `HAVE_BRIDGE_SECONDARY_BUS_RESET`, `VFS_UNLINK_HAS_IDMAP_ARG`,
   `HAVE_FTRACE_REGS_OPS`, `HAVE_KFREE_SENSITIVE`, `HAVE_MAX_PAGE_ORDER`,
   `HAVE_CLASS_CREATE_1_ARG`, `HAVE_DEVNODE_CONST`,
   `HAVE_DCORE_IOVA_VM_CTX_VFIO_DEVICE`, `HAVE_DCORE_IOVA_VM_CTX_PAGE_ARRAY`,
   `HAVE_POLL_T`, `HAVE_UP_DOWN_READ_MMAP_LOCK_ARG`,
   `HAVE_GET_USER_PAGES_REMOTE_6_ARG`, `HAVE_RTC_KTIME_TO_TM`.
   File against `github.com/amd/MxGPU-Virtualization`.

6. **MI300X PCI config space corruption after VFIO reset** — PF passthrough causes
   permanent config space corruption (all 0xFF). Device doesn't recover after PCI
   remove+rescan; requires full host reboot. Only VF passthrough via GIM works.
   File against AMD firmware/driver team.

## Enhancements

1. **GPU operator GIM lifecycle via KMM** — The operator should build GIM for the
   running kernel via KMM, load it before amdgpu (via `softdep` or module ordering),
   and manage VF creation. Currently GIM is built and loaded manually.

2. **GPU DRA driver VFIO-only mode** — The init container waits for `/sys/class/kfd`
   which doesn't exist when amdgpu is blacklisted. Add a flag or auto-detect to skip
   the kfd check when GIM is managing all GPUs.

3. **Topology coordinator configurable NIC count** — The eighth partition hardcodes
   2 NICs per NUMA node. Should be configurable per partition type or per device class.

4. **Topology coordinator VfConfig propagation** — The coordinator should support
   adding opaque device configs to expanded sub-requests, so VfConfig `driver: vfio-pci`
   can be specified at the partition level without patching the DeviceClass globally.

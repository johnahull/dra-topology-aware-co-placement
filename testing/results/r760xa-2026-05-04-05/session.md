# R760xa Session — 2026-05-04/05

## System

- **Host:** nvd-srv-31.nvidia.eng.rdu2.dc.redhat.com (Dell R760xa)
- **IP:** 10.6.135.10
- **OS:** Fedora Linux 43 (Server Edition), kernel 6.19.13-200.fc43.x86_64
- **K8s:** v1.37.0-alpha.0.356+56aa03c800abc7-dirty (kubeadm, single node)
- **Container runtime:** containerd 2.2.3
- **KubeVirt:** v1.8.1 (stock upstream images, virt-operator scaled to 0)
- **KubeVirt feature gates:** HostDevices, DRA, HostDevicesWithDRA, GPUsWithDRA, CPUManager, ReservedOverheadMemlock
- **Root feature gate:** NOT enabled (default non-root mode)
- **cpuManagerPolicy:** none

## Hardware

- 2x NVIDIA A40 GPUs (both on NUMA 0, both on nvidia driver)
  - gpu-0: 0000:4a:00.0, pcieRoot pci0000:49
  - gpu-1: 0000:61:00.0, pcieRoot pci0000:60
- 2x NUMA nodes, 128 CPUs (64 per NUMA)
- Multiple Intel NICs across both NUMA nodes

## DRA Drivers Deployed

| Driver | Image | Mode |
|---|---|---|
| gpu.nvidia.com | localhost/nvidia-dra-driver:combined | PassthroughSupport=true, DeviceMetadata=true |
| dra.cpu | upstream dra-driver-cpu | --cpu-device-mode=grouped --group-by=numanode |
| dra.memory | upstream dra-driver-memory | default |
| dra.net | upstream dranet | default |
| compute-domain.nvidia.com | upstream topology coordinator | default |

### NVIDIA GPU DRA Driver — combined branch

The `combined` image merges two branches:
- `fix/vfio-lifecycle-v2`: VFIO discovery filter (only advertise GPUs bound to vfio-pci) + Unconfigure pre-bound skip
- `feature/standardized-topology-attrs`: publish `resource.kubernetes.io/numaNode`, `cpuSocketID`, `pcieRoot`, `pciBusID`
- DeviceMetadata feature gate lowered to v25.12

## ResourceSlices

```
gpu.nvidia.com:           gpu-0, gpu-1 (no gpu-vfio — both GPUs on nvidia driver)
dra.cpu:                  cpudevnuma000 (NUMA 0, grouped), cpudevnuma001 (NUMA 1, grouped)
dra.memory:               2 slices (NUMA 0, NUMA 1)
dra.net:                  multiple NICs across both NUMA nodes
compute-domain.nvidia.com: topology coordinator partitions
```

## Session Activities

### 1. KubeVirt VFIO memlock investigation (PR #17675 → #17696)

Investigated vladikr's review comments on PR #17675. Reproduced the memlock issue on stock KubeVirt main.

**Key findings:**
- Stock v1.8.1 image on this system was a **locally-built patched version** tagged as upstream. Pulled real upstream image (digest `sha256:4b53dafe...`) to test properly.
- Real stock v1.8.1 blocks DRA HostDevices at `permittedHostDevices` validation (fixed on main).
- Built virt-controller from main — DRA HostDevices validation passes but VM fails with memlock error in non-root mode.
- Root cause: libvirt calls `prlimit(QEMU_pid, RLIMIT_MEMLOCK, 2^53-1)` from virtqemud. Requires `CAP_SYS_RESOURCE`. Non-root container only has `NET_BIND_SERVICE`.
- virt-handler's external prlimit works (confirmed via verbosity 5 logs: `Cur: 18572378928 Max:18572378928`) but libvirt's internal prlimit fails.
- Fix: force root mode (`markAsNonroot` skip in webhook) + add `CAP_SYS_RESOURCE` for VFIO VMIs.
- Tested successfully: VM boots with `RunAsUser=0`, caps `["NET_BIND_SERVICE", "SYS_NICE", "SYS_RESOURCE"]`, GPU passed through.

**Filed:**
- Issue: [kubevirt#17694](https://github.com/kubevirt/kubevirt/issues/17694)
- Draft PR: [kubevirt#17696](https://github.com/kubevirt/kubevirt/pull/17696) (force root + SYS_RESOURCE)
- Draft PR: [kubevirt#17708](https://github.com/kubevirt/kubevirt/pull/17708) (KV-8: skip cpumanager label for DRA)

### 2. GPU driver cleanup — remove phantom VFIO devices

Both GPUs rebound to nvidia driver. Deployed combined NVIDIA DRA driver image with VFIO discovery filter. After restart, ResourceSlice correctly shows only `gpu-0` and `gpu-1`, no `gpu-vfio-*` devices.

### 3. CPU driver switch to grouped mode

Switched DRA CPU driver from individual mode (128 devices) to grouped mode (2 devices: cpudevnuma000, cpudevnuma001). Fixed `--hostname-override` to use actual node name. Deleted stale ResourceSlice with individual devices.

### 4. Quarter partition test — 3 pods

Created 3 quarter pods: 2 on NUMA 0 (each with 1 GPU), 1 on NUMA 1 (no GPU).

#### Claims

```yaml
# quarter-1: NUMA 0
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: quarter-1
spec:
  devices:
    requests:
    - name: partition
      exactly:
        deviceClassName: compute-domain-nvidia-com-dra-cpu-dra-memory-d-ba1838c2-quarter-numa0
---
# quarter-2: NUMA 0
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: quarter-2
spec:
  devices:
    requests:
    - name: partition
      exactly:
        deviceClassName: compute-domain-nvidia-com-dra-cpu-dra-memory-d-ba1838c2-quarter-numa0
---
# quarter-3: NUMA 1
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: quarter-3
spec:
  devices:
    requests:
    - name: partition
      exactly:
        deviceClassName: compute-domain-nvidia-com-dra-cpu-dra-memory-d-ba1838c2-quarter-numa1
```

#### Pods

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: quarter-pod-1
spec:
  containers:
  - name: workload
    image: registry.k8s.io/pause:3.10
  resourceClaims:
  - name: quarter-1
    resourceClaimName: quarter-1
---
apiVersion: v1
kind: Pod
metadata:
  name: quarter-pod-2
spec:
  containers:
  - name: workload
    image: registry.k8s.io/pause:3.10
  resourceClaims:
  - name: quarter-2
    resourceClaimName: quarter-2
---
apiVersion: v1
kind: Pod
metadata:
  name: quarter-pod-3
spec:
  containers:
  - name: workload
    image: registry.k8s.io/pause:3.10
  resourceClaims:
  - name: quarter-3
    resourceClaimName: quarter-3
```

#### VFIO GPU VM test (KV-7 investigation)

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: test-main
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu-vfio.nvidia.com
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: gpu-vfio.nvidia.com
spec:
  selectors:
  - cel:
      expression: "device.driver == 'gpu.nvidia.com' && device.attributes['gpu.nvidia.com'].type == 'vfio'"
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-main-vm
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 4
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          hostDevices:
          - claimName: test-main
            name: gpu0
            requestName: gpu
          interfaces:
          - bridge: {}
            name: default
        machine:
          type: q35
        memory:
          guest: 4Gi
        resources:
          requests:
            memory: 6Gi
      networks:
      - name: default
        pod: {}
      resourceClaims:
      - name: test-main
        resourceClaimName: test-main
      volumes:
      - containerDisk:
          image: quay.io/containerdisks/fedora:41
          imagePullPolicy: IfNotPresent
        name: containerdisk
```

#### Results

| Claim | Pod | NUMA | GPU | CPUs | Memory | NICs |
|---|---|---|---|---|---|---|
| quarter-1 | quarter-pod-1 | 0 | gpu-0 | cpudevnuma000 | memory-qpcjhb | pci-0000-02-00-0, 02-00-1, 22-00-1 |
| quarter-2 | quarter-pod-2 | 0 | gpu-1 | cpudevnuma000 | memory-qpcjhb | pci-0000-37-00-0, 37-00-1, 37-00-2 |
| quarter-3 | quarter-pod-3 | 1 | (none) | cpudevnuma001 | memory-bzklrf | pci-0000-a0-00-0, a0-00-1, b5-00-0 |

All devices NUMA-aligned. Both GPUs correctly assigned to NUMA 0 pods. NUMA 1 pod has no GPU (both GPUs are on NUMA 0).

## Issues Found This Session

| Issue | Component | Status |
|---|---|---|
| KV-7: VFIO non-root memlock prlimit | KubeVirt | Draft PR [#17696](https://github.com/kubevirt/kubevirt/pull/17696) |
| KV-8: cpumanager label blocks DRA | KubeVirt | Draft PR [#17708](https://github.com/kubevirt/kubevirt/pull/17708) |
| Stale v1.8.1 image (locally built, tagged as upstream) | Test env | Fixed by pulling real upstream image |
| CPU driver individual mode exceeds 32-device claim limit | dra-driver-cpu | Fixed by switching to grouped mode |
| CPU driver hostname-override empty | dra-driver-cpu | Fixed by setting to actual node name |
| GPU driver stale ResourceSlice after restart | NVIDIA DRA driver | Fixed by restarting pod |
| Coordinator uses dra.net (all NICs) instead of dra.net-sriov-vf | Topology coordinator | Workaround: patch device class after generation, scale down coordinator |
| dra.net-sriov-vf CEL expression wrong (.BoolValue) | dranet DeviceClass | Fixed: `has(device.attributes['dra.net'].isSriovVf) && ...` |
| dranet advertises PCI NICs without interfaces (Broadcom BCM5720) | dranet | Investigating — PCI devices at 0000:02:00.0/1 have no /net dir but dranet still advertises them. Filter code added but not effective — `discoverNetworkInterfaces` may be associating an interface via alternate sysfs path |
| Direct claims with matchAttribute work (GPU+VF+CPU) | Test success | All 3 pods NUMA-aligned without coordinator |
| Coordinator claims with patched device class work | Test success | 3 quarter pods: 2 on NUMA 0 (1 GPU each), 1 on NUMA 1 |

# Standardized Topology Attributes Test — NVIDIA A40

**Date:** 2026-04-23
**Hardware:** nvd-srv-31 — 2x Intel Xeon Gold 6548Y+, 2x NVIDIA A40, ConnectX-7 + ConnectX-6 Dx + BlueField-3
**OS:** Fedora 43, kernel 6.17.1
**K8s:** 1.36.0 GA (tests 1-5), custom v1.37.0-alpha.0 with enforcement:preferred (tests E-1+)

## Device Topology

| Device | BDF | NUMA | Socket | PCIe Root |
|--------|-----|------|--------|-----------|
| NVIDIA A40 GPU | `4a:00.0` | 0 | 0 | `pci0000:49` |
| NVIDIA A40 GPU | `61:00.0` | 0 | 0 | `pci0000:60` |
| ConnectX-7 NIC | `37:00.0` | 0 | 0 | `pci0000:36` |
| BlueField-3 NIC | `a0:00.0` | 1 | 1 | `pci0000:9f` |
| ConnectX-6 Dx NIC | `b5:00.0` | 1 | 1 | `pci0000:b4` |

Both GPUs and ConnectX-7 on NUMA 0 but different PCIe roots. pcieRoot match for GPU+NIC: 0 of 2.

## Progress

### NVIDIA GPU DRA Driver — Deployed

- NVIDIA driver 580.142 (CUDA 13.0) installed via RPM Fusion akmod
- GPU Operator v26.3.1 installed (driver disabled, toolkit enabled)
- DRA driver deployed via Helm chart with custom image (`localhost/nvidia-dra-driver:standardized-v2`)
- ResourceSlice published with standardized attributes

**ResourceSlice attributes for GPU `4a:00.0`:**
```yaml
resource.kubernetes.io/cpuSocketID:
  int: 0
resource.kubernetes.io/numaNode:
  int: 0
resource.kubernetes.io/pciBusID:
  string: 0000:4a:00.0
resource.kubernetes.io/pcieRoot:
  string: pci0000:49
```

### SR-IOV NIC DRA Driver — Blocked

NIC VF creation fails on all NICs with "not enough MMIO resources for SR-IOV". BIOS needs SR-IOV / Above 4G Decoding enabled. Testing continues with GPU + CPU.

### CPU DRA Driver — Deployed

- Built from `johnahull/dra-driver-cpu` branch `feature/standardized-topology-attrs`
- Deployed as DaemonSet with NRI socket mount
- ResourceSlice published with standardized attributes

**CPU ResourceSlice attributes:**
```yaml
# NUMA 0 device
resource.kubernetes.io/numaNode:
  int: 0
resource.kubernetes.io/cpuSocketID:
  int: 0

# NUMA 1 device
resource.kubernetes.io/numaNode:
  int: 1
resource.kubernetes.io/cpuSocketID:
  int: 1
```

### Memory DRA Driver — Deployed

- Built from `johnahull/dra-driver-memory` branch `feature/standardized-topology-attrs`
- Fixed: cgroup2 preflight (cherry-picked), NRI `UpdatePodSandbox` event (containerd 2.1.6 doesn't support 0x800 event flag — commented out the handler)
- ResourceSlice published with standardized attributes

**Memory ResourceSlice attributes:**
```yaml
# NUMA 0 device
resource.kubernetes.io/numaNode:
  int: 0
resource.kubernetes.io/cpuSocketID:
  int: 0

# NUMA 1 device
resource.kubernetes.io/numaNode:
  int: 1
resource.kubernetes.io/cpuSocketID:
  int: 1
```

## Tests

### Test A-3: numaNode aligns GPU + CPU + Memory (3 drivers) — PASSED

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu, mem]
```

**Result:** All three on NUMA 0:
```json
[
  {"device": "gpu-0", "driver": "gpu.nvidia.com", "request": "gpu"},
  {"device": "cpudevnuma000", "driver": "dra.cpu", "request": "cpu",
   "consumedCapacity": {"dra.cpu/cpu": "64"}},
  {"device": "memory-9xskns", "driver": "dra.memory", "request": "mem",
   "consumedCapacity": {"size": "1Mi"}}
]
```

One constraint, three drivers, standardized attribute name. No topology coordinator, no ConfigMaps.

### Test A: numaNode aligns GPU + CPU — PASSED

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

**Result:** Allocated GPU `gpu-0` (NUMA 0) + CPU `cpudevnuma000` (NUMA 0). Both on NUMA 0 — standardized `numaNode` matched cross-driver.

```json
[
  {"device": "gpu-0", "driver": "gpu.nvidia.com", "request": "gpu"},
  {"device": "cpudevnuma000", "driver": "dra.cpu", "request": "cpu",
   "consumedCapacity": {"dra.cpu/cpu": "64"}}
]
```

**This is the core proof:** one `matchAttribute` constraint with a standardized attribute name aligns devices from two different drivers — no ConfigMaps, no topology coordinator, no middleware.

### Test B: pcieRoot for GPU+NIC fails — Blocked (no NIC VFs)

### Test C: pcieRoot + numaNode both required fails — Blocked (no NIC VFs)

### Test D: cpuSocketID aligns GPU + CPU — PASSED

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/cpuSocketID
  requests: [gpu, cpu]
```

**Result:** Allocated GPU `gpu-0` (socket 0) + CPU `cpudevnuma000` (socket 0). Both on socket 0.

```json
[
  {"device": "gpu-0", "driver": "gpu.nvidia.com", "request": "gpu"},
  {"device": "cpudevnuma000", "driver": "dra.cpu", "request": "cpu",
   "consumedCapacity": {"dra.cpu/cpu": "64"}}
]
```

### Test A-4: numaNode aligns GPU + NIC + CPU + Memory (4 drivers) — PASSED

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
```

**Result:** All four on NUMA 0:
```json
[
  {"device": "gpu-0", "driver": "gpu.nvidia.com", "request": "gpu"},
  {"device": "0000-37-00-1", "driver": "sriovnetwork.k8snetworkplumbingwg.io", "request": "nic"},
  {"device": "cpudevnuma000", "driver": "dra.cpu", "request": "cpu",
   "consumedCapacity": {"dra.cpu/cpu": "64"}},
  {"device": "memory-2qxc6p", "driver": "dra.memory", "request": "mem",
   "consumedCapacity": {"size": "1Mi"}}
]
```

**One constraint, four drivers, standardized attribute name. No topology coordinator, no ConfigMaps, no middleware.**

## enforcement:preferred Tests

Requires all 5 custom K8s binaries from `johnahull/kubernetes` branch `feature/enforcement-preferred`: kube-apiserver, kube-scheduler, kube-controller-manager, kubelet, kubectl.

### Test E-1: pcieRoot preferred + numaNode required (GPU + CPU) — PASSED

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, cpu]
  enforcement: Preferred
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

**Result:** GPU + CPU on NUMA 0. pcieRoot constraint relaxed (CPU doesn't publish pcieRoot):
```json
[
  {"device": "gpu-0", "driver": "gpu.nvidia.com", "request": "gpu"},
  {"device": "cpudevnuma000", "driver": "dra.cpu", "request": "cpu",
   "consumedCapacity": {"dra.cpu/cpu": "64"}}
]
```

**This proves enforcement:preferred works:** The same claim with `enforcement: Required` on pcieRoot (Test 5) fails because CPU has no pcieRoot. With `enforcement: Preferred`, the scheduler relaxes the pcieRoot constraint and satisfies numaNode instead. The distance hierarchy works.

## KubeVirt DRA-Native Dual-NUMA VM — PASSED

Requires patched KubeVirt v1.8.1 from `johnahull/kubevirt` branch `feature/dra-vfio-numa-passthrough-v1.8.1` and patched SR-IOV DRA driver from `johnahull/dra-driver-sriov` branch `feature/dra-topology-co-placement`.

### Test K-1: Dual-NUMA VM with DRA CPU + NIC claims — PASSED

**VMI spec:** 8 vCPUs (2 sockets × 4 cores), 8Gi memory, `guestMappingPassthrough` enabled, no `dedicatedCpuPlacement`, no hugepages.

**DRA claims:**
- `vm-cpu-numa0`: DRA CPU from NUMA 0
- `vm-cpu-numa1`: DRA CPU from NUMA 1
- `vm-nic-numa0`: SR-IOV VF from ConnectX-7 (NUMA 0), driver: vfio-pci
- `vm-nic-numa1`: SR-IOV VF from ConnectX-6 Dx (NUMA 1), driver: vfio-pci

**Guest verification:**
```
$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3
node 0 size: 3961 MB
node 1 cpus: 4 5 6 7
node 1 size: 3972 MB
node distances:
node   0   1
  0:  10  20
  1:  20  10

$ for dev in /sys/class/net/*/device/numa_node; do echo $(basename $(dirname $(dirname $dev))): NUMA=$(cat $dev); done
enp253s0: NUMA=0   # ConnectX-7 VF
enp255s0: NUMA=1   # ConnectX-6 Dx VF
```

**What this proves:**
- Guest sees 2 NUMA nodes with correct CPU/memory split
- VFIO NICs placed on correct guest NUMA nodes via pxb-pcie expander buses
- No kubelet CPU manager, no topology manager, no hugepages required
- DRA CPU driver handles CPU allocation per NUMA via NRI
- DRA SR-IOV driver handles NIC VFIO passthrough with KEP-5304 metadata
- KubeVirt builds guest NUMA topology entirely from DRA claim allocations
- **First DRA-native guest NUMA topology for KubeVirt VMs**

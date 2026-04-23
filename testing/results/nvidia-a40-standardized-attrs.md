# Standardized Topology Attributes Test — NVIDIA A40

**Date:** 2026-04-23
**Hardware:** nvd-srv-31 — 2x Intel Xeon Gold 6548Y+, 2x NVIDIA A40, ConnectX-7 + ConnectX-6 Dx + BlueField-3
**OS:** Fedora 43, kernel 6.17.1
**K8s:** 1.36.0 GA

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

### Memory DRA Driver — Pending

## Tests

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

### Test D: cpuSocketID aligns GPU + CPU — Pending

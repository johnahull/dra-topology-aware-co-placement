# Proposal: NVSwitch Topology Attribute for NVIDIA GPU DRA Driver

## Problem

When passing multiple GPUs into a KubeVirt VM (or allocating multiple GPUs to a pod), the GPUs must be correctly paired based on their NVLink/NVSwitch physical topology. Arbitrarily pairing GPUs can result in:

- **Asymmetric NVLink bandwidth** — GPUs on different NVSwitch domains get PCIe-only interconnect instead of NVLink
- **Cross-VM NVLink leakage** — in Full Passthrough mode, NVLinks between GPUs in different VMs must be disabled
- **Invalid partition sizes** — DGX B200/B300 with 2 NVSwitches only support specific GPU groupings (groups of 4)

Currently, the NVIDIA GPU DRA driver (`k8s-dra-driver-gpu`) does not publish any attribute indicating which NVSwitch group a GPU belongs to. Admins must manually determine valid GPU pairings.

## Proposal

Add an `nvSwitchGroup` device attribute to each GPU published in the ResourceSlice. This attribute identifies which NVSwitch domain the GPU is physically connected to, enabling the Kubernetes scheduler to enforce correct GPU pairing through `matchAttribute` constraints.

### Attribute Definition

```
gpu.nvidia.com/nvSwitchGroup: <int>
```

- **Type:** IntAttribute
- **Value:** Integer identifying the NVSwitch group (0, 1, etc.)
- **Scope:** Per-GPU device in the ResourceSlice
- **Presence:** Only on systems with NVSwitch (DGX/HGX). Absent on PCIe-only systems.

### Examples

**DGX B200/B300 (2 NVSwitches, 8 GPUs):**
```
GPU 0: nvSwitchGroup=0    GPU 4: nvSwitchGroup=1
GPU 1: nvSwitchGroup=0    GPU 5: nvSwitchGroup=1
GPU 2: nvSwitchGroup=0    GPU 6: nvSwitchGroup=1
GPU 3: nvSwitchGroup=0    GPU 7: nvSwitchGroup=1
```

**DGX H100 (4 NVSwitches, 8 GPUs):**
```
GPU 0: nvSwitchGroup=0    GPU 4: nvSwitchGroup=2
GPU 1: nvSwitchGroup=0    GPU 5: nvSwitchGroup=2
GPU 2: nvSwitchGroup=1    GPU 6: nvSwitchGroup=3
GPU 3: nvSwitchGroup=1    GPU 7: nvSwitchGroup=3
```

(Exact groupings vary by platform — determined from NVML topology queries.)

## Implementation

### Changes to k8s-dra-driver-gpu

#### 1. Topology Discovery (`cmd/gpu-kubelet-plugin/nvlib.go`)

Add a function to detect NVSwitch groups using existing NVML bindings:

```go
func (l *deviceLib) detectNvSwitchGroups() (map[string]int, error) {
    groups := make(map[string]int) // GPU UUID → group ID

    // Get all GPU handles
    var handles []nvml.Device
    l.visitDevices(func(i int, d nvml.Device) {
        handles = append(handles, d)
    })

    if len(handles) < 2 {
        return groups, nil
    }

    // Check if first GPU has NVSwitch connectivity
    // GetTopologyCommonAncestor returns TOPOLOGY_NVSWITCH for NVSwitch-connected GPUs
    _, ret := handles[0].GetTopologyCommonAncestor(handles[1])
    if ret != nvml.SUCCESS {
        return groups, nil // No NVSwitch topology available
    }

    // Build connectivity groups using union-find
    // GPUs connected via the same NVSwitch are in the same group
    parent := make([]int, len(handles))
    for i := range parent {
        parent[i] = i
    }
    find := func(x int) int {
        for parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }
    union := func(a, b int) {
        pa, pb := find(a), find(b)
        if pa != pb {
            parent[pa] = pb
        }
    }

    for i := 0; i < len(handles); i++ {
        for j := i + 1; j < len(handles); j++ {
            ancestor, ret := handles[i].GetTopologyCommonAncestor(handles[j])
            if ret == nvml.SUCCESS && ancestor == nvml.TOPOLOGY_NVSWITCH {
                union(i, j)
            }
        }
    }

    // Assign sequential group IDs
    groupMap := make(map[int]int) // root → group ID
    nextGroup := 0
    for i, h := range handles {
        uuid, _ := h.GetUUID()
        root := find(i)
        if _, ok := groupMap[root]; !ok {
            groupMap[root] = nextGroup
            nextGroup++
        }
        groups[uuid] = groupMap[root]
    }

    return groups, nil
}
```

The key NVML function is `GetTopologyCommonAncestor()` which returns:
- `TOPOLOGY_INTERNAL` — same GPU
- `TOPOLOGY_SINGLE` — same PCIe root
- `TOPOLOGY_MULTIPLE` — different PCIe roots
- `TOPOLOGY_HOSTBRIDGE` — same host bridge
- `TOPOLOGY_NVSWITCH` — connected via NVSwitch

GPUs that return `TOPOLOGY_NVSWITCH` for each other are on the same NVSwitch domain and can be grouped.

#### 2. Attribute Publishing (`cmd/gpu-kubelet-plugin/deviceinfo.go`)

Add the attribute to `GpuInfo.Attributes()`:

```go
// In Attributes() method, after existing attributes:
if gi.nvSwitchGroup >= 0 {
    attrs["gpu.nvidia.com/nvSwitchGroup"] = resourceapi.DeviceAttribute{
        IntValue: ptr.To(int64(gi.nvSwitchGroup)),
    }
}
```

#### 3. Alternative: Use Existing Clique ID

The `compute-domain-kubelet-plugin` already detects NVLink fabric cliques via `GetGpuFabricInfo()` (`nvlib.go:195-363`). The clique ID (`{clusterUUID}.{cliqueId}`) identifies the fabric group. This could be published as an attribute instead:

```
gpu.nvidia.com/fabricCliqueId: "a1b2c3d4-...-5678.0"
```

However, `fabricCliqueId` is a string (UUID format) while `nvSwitchGroup` is an integer. The integer form is simpler for `matchAttribute` constraints and aligns with how the topology coordinator handles other attributes.

### Changes to Topology Coordinator

No code changes needed. The coordinator already handles any device attribute as an alignment constraint. An admin would create a topology rule:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvswitch-group-rule
  labels:
    nodepartition.dra.k8s.io/topology-rule: "true"
data:
  driver: gpu.nvidia.com
  attribute: gpu.nvidia.com/nvSwitchGroup
  type: int
  partitioning: group
  constraint: match
```

This tells the coordinator to:
1. Group GPUs by their `nvSwitchGroup` value when building partitions
2. Add `matchAttribute=gpu.nvidia.com/nvSwitchGroup` constraints to DeviceClasses
3. Ensure multi-GPU allocations only pair GPUs within the same NVSwitch domain

### Integration with Partition DeviceClasses

With the attribute published, the topology coordinator automatically creates correct partitions:

**DGX B200 (2 NVSwitches) with NPS4:**
```
eighth   → 1 GPU (any)
quarter  → 2 GPUs (same NVSwitch group)
half     → 4 GPUs (all on one NVSwitch)
full     → 8 GPUs (both NVSwitches)
```

The `matchAttribute` constraint on `nvSwitchGroup` ensures quarter/half allocations never cross NVSwitch boundaries.

## Alternatives Considered

### 1. Use pcieRoot Alone
PCIe root already groups GPU+NIC pairs by physical location. However, NVLink/NVSwitch topology doesn't always follow PCIe topology — GPUs on different PCIe roots can share an NVSwitch.

### 2. Static Configuration via ConfigMap
Admins could manually define GPU groups in a ConfigMap. This works but requires per-server configuration and doesn't adapt to hardware changes.

### 3. Detect from P2P Status
`GetP2PStatus()` returns whether two GPUs can communicate via P2P. This could be used to infer groups, but it's less precise than `GetTopologyCommonAncestor()` — P2P can work over PCIe as well as NVLink.

## Impact

- **NVIDIA GPU DRA driver**: ~100 lines of new code in `nvlib.go` and `deviceinfo.go`
- **Topology coordinator**: Zero code changes — existing topology rule framework handles it
- **Users**: Multi-GPU DeviceClasses automatically enforce NVSwitch-aware pairing
- **Backward compatibility**: Attribute is optional — systems without NVSwitch simply don't publish it

## References

- [NVML API - GetTopologyCommonAncestor](https://docs.nvidia.com/deploy/nvml-api/group__nvmlDeviceQueries.html)
- [NVIDIA GPU Virtualization Guide - NVSwitch Multitenancy](https://docs.nvidia.com/datacenter/tesla/gpu-passthrough/)
- [k8s-dra-driver-gpu source](https://github.com/NVIDIA/k8s-dra-driver-gpu)
- NVLink fabric clique detection: `cmd/compute-domain-kubelet-plugin/nvlib.go:195-363`

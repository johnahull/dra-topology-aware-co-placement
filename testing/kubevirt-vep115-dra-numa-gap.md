# KubeVirt VEP 115 + DRA: Guest NUMA Topology Gap

## Summary

KubeVirt's `guestMappingPassthrough` (VEP 115) creates guest NUMA topology based on the kubelet's CPU/memory NUMA assignment from the topology manager. It does NOT consider DRA device NUMA placement from KEP-5304 metadata. This means DRA-provisioned VFIO devices always show `numa_node=-1` in the guest, even when the host-side NUMA placement is correct.

## Problem

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

## Root Cause

VEP 115's `guestMappingPassthrough` in `pkg/virt-launcher/virtwrap/converter/converter.go` builds the guest NUMA topology from the kubelet's topology manager hints — specifically from the CPU affinity of the pod's cgroup. It counts how many host NUMA nodes the pod's CPUs span and creates that many guest NUMA nodes.

With DRA, the device NUMA information comes from KEP-5304 metadata (`numaNode` attribute in `/var/run/kubernetes.io/dra-device-attributes/`), NOT from the kubelet's topology manager. The topology manager only handles CPU and memory placement — DRA devices are invisible to it.

When the pod requests only 8 CPUs on a 128-CPU 2-NUMA machine, the topology manager places all 8 on a single NUMA node. `guestMappingPassthrough` sees 1 NUMA node and creates a 1-NUMA guest, regardless of the DRA devices spanning both host NUMA nodes.

## Proposed Fix

KubeVirt should also read the `numaNode` attribute from KEP-5304 metadata for each DRA host device and use it to:

1. **Determine guest NUMA node count** — union of CPU NUMA nodes AND DRA device NUMA nodes
2. **Place pxb-pcie expander buses** on the correct guest NUMA node based on the device's `numaNode` from metadata
3. **Attach VFIO devices** to the matching pxb-pcie bus

### Implementation

In `pkg/virt-launcher/virtwrap/converter/converter.go`, where `guestMappingPassthrough` builds the guest topology:

1. Read KEP-5304 metadata for each DRA host device to get its `numaNode`
2. Build a set of all NUMA nodes from both CPU affinity AND device metadata
3. Create guest NUMA nodes for each unique host NUMA node
4. When placing VFIO devices on pxb-pcie buses, use the device's `numaNode` from metadata instead of defaulting to the CPU's NUMA node

### Key Files

- `pkg/virt-launcher/virtwrap/converter/converter.go` — guest NUMA topology builder
- `pkg/virt-launcher/virtwrap/device/hostdevice/dra/generic_hostdev.go` — DRA host device creation
- `pkg/dra/utils.go` — KEP-5304 metadata reader (already reads `pciBusID`, needs `numaNode`)

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

## Tested On

- Dell XE9680 (2-socket, 2 NUMA, 8x MI300X GPUs)
- K8s 1.36.0-rc.0, KubeVirt 1.8.1
- GIM SR-IOV GPU VFs with VFIO passthrough via DRA
- Topology coordinator per-driver CEL selectors for NUMA placement

## Workaround

Request enough CPUs to force the kubelet topology manager to span both NUMA nodes (65+ CPUs on this machine). This makes `guestMappingPassthrough` create 2 guest NUMA nodes. Not practical for small VMs.

## Related

- VEP 115: PCI NUMA-Aware Topology
- KEP-5304: Native Device Metadata API
- KEP-5491: Standard Topology Attributes (proposed `resource.kubernetes.io/numaNode`)

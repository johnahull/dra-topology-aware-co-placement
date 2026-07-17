# KEP-6072 Standard Topology Attributes — Driver Adoption Guide

Guide for DRA driver maintainers adopting the standardized `resource.kubernetes.io/numaNode` attribute from [KEP-6072](https://github.com/kubernetes/enhancements/issues/6072).

**Status:** K8s PR [#139929](https://github.com/kubernetes/kubernetes/pull/139929) merged 2026-07-16.

---

## What KEP-6072 Adds

Three standardized device attribute names in `k8s.io/dynamic-resource-allocation/deviceattribute`:

| Attribute | Type | Description |
|---|---|---|
| `resource.kubernetes.io/numaNode` | `int` or `ints` (list) | NUMA node affinity. Scalar = physical node. List = physical node + SLIT-reachable same-socket nodes. |
| `resource.kubernetes.io/pcieRoot` | `string` | PCIe Root Complex (e.g., `pci0000:00`). Devices sharing a root are under the same PCIe hierarchy. |
| `resource.kubernetes.io/pciBusID` | `string` | PCI Bus address in extended BDF notation (e.g., `0000:0c:00.0`). |

These enable cross-driver device alignment — a GPU, NIC, and NVMe on the same NUMA node can be co-located using `matchAttribute` constraints without knowing each driver's vendor-specific attribute names.

## The Backward Compatibility Problem

The `numaNode` attribute has two forms:

| Form | K8s Version | Feature Gate | API Field |
|---|---|---|---|
| **Scalar** (int) | Any (1.33+) | None required | `DeviceAttribute.IntValue` |
| **List** (ints) | 1.37+ | `DRAListTypeAttributes=true` | `DeviceAttribute.IntValues` |

**The list form will be rejected by API servers before 1.37.** The `IntValues` field does not exist in the ResourceSlice schema on older clusters. If a driver publishes `resource.kubernetes.io/numaNode` with `IntValues: [0, 1]`, the API server returns a validation error and the ResourceSlice is not created.

This means drivers must detect the cluster version and choose the right form.

## How to Adopt

### Step 1: Bump the dependency

Add or update the `k8s.io/dynamic-resource-allocation` dependency to pick up the `deviceattribute` package with the KEP-6072 helpers:

```bash
go get k8s.io/dynamic-resource-allocation@latest
go mod vendor  # if using vendoring
```

### Step 2: Import the helpers

```go
import "k8s.io/dynamic-resource-allocation/deviceattribute"
```

### Step 3: Call the helper in your GetDevice() / device publishing code

The key function is:

```go
func GetNUMANodeAttributeByPCIBusID(pciBusID string, listEnabled bool) (DeviceAttribute, error)
```

For devices that already know their NUMA node (CPU, memory):

```go
func GetNUMANodeAttribute(numaNode int, listEnabled bool) (DeviceAttribute, error)
```

**Parameters:**
- `pciBusID` — the PCI address in BDF format (e.g., `"0000:0c:00.0"`)
- `numaNode` — the NUMA node ID (must be >= 0; -1 means no affinity, don't publish)
- `listEnabled` — **you must set this correctly** (see Step 4)

**Returns:**
- `listEnabled=true` → `DeviceAttribute` with `IntValues` (SLIT-based list: physical node first, then equidistant same-socket nodes)
- `listEnabled=false` → `DeviceAttribute` with `IntValue` (scalar physical node)
- Both use the standardized name `resource.kubernetes.io/numaNode`

**Example (PCI device like a GPU or NIC):**

```go
func (d *MyDevice) GetDevice(listEnabled bool) resourceapi.Device {
    attrs := map[resourceapi.QualifiedName]resourceapi.DeviceAttribute{
        // ...your existing attributes...
    }

    // Standard NUMA attribute
    numaAttr, err := deviceattribute.GetNUMANodeAttributeByPCIBusID(d.PCIAddress, listEnabled)
    if err != nil {
        klog.Warningf("No NUMA affinity for %s: %v", d.PCIAddress, err)
    } else {
        attrs[numaAttr.Name] = numaAttr.Value
    }

    // Standard PCIe root attribute
    pcieAttr, err := deviceattribute.GetPCIeRootAttributeByPCIBusID(d.PCIAddress)
    if err == nil {
        attrs[pcieAttr.Name] = pcieAttr.Value
    }

    // Standard PCI Bus ID attribute
    busAttr, err := deviceattribute.GetPCIBusIDAttribute(d.PCIAddress)
    if err == nil {
        attrs[busAttr.Name] = busAttr.Value
    }

    return resourceapi.Device{
        Name:       d.Name(),
        Attributes: attrs,
    }
}
```

**Example (non-PCI device like CPU or memory):**

```go
numaAttr, err := deviceattribute.GetNUMANodeAttribute(cpuNumaNode, listEnabled)
if err == nil {
    attrs[numaAttr.Name] = numaAttr.Value
}
```

### Step 4: Control `listEnabled` based on cluster version

The driver cannot detect the cluster's `DRAListTypeAttributes` feature gate — it's a per-process setting on the API server, not queryable via API. The driver must be told.

**Option A: CLI flag (recommended for standalone drivers)**

```go
&cli.BoolFlag{
    Name:        "numa-list",
    Usage:       "Publish numaNode as SLIT-based list (requires DRAListTypeAttributes). Set false for K8s < 1.37.",
    Value:       true,
    Destination: &flags.numaListEnabled,
    EnvVars:     []string{"NUMA_LIST_ENABLED"},
},
```

Default to `true` (list form) since K8s 1.37 is where DRA is GA. Set to `false` when deploying on older clusters.

**Option B: Auto-detect from API server version**

```go
func shouldEnableNUMAList(client kubernetes.Interface) bool {
    v, err := client.Discovery().ServerVersion()
    if err != nil {
        return false  // safe default
    }
    minor, err := strconv.Atoi(strings.TrimSuffix(v.Minor, "+"))
    if err != nil {
        return false
    }
    return minor >= 37
}
```

This works but is imprecise — `DRAListTypeAttributes` may be disabled even on 1.37. If the gate is off but the driver publishes lists, the ResourceSlice will fail to create. The driver should treat that failure as fatal and fall back.

**Option C: Feature gate in the driver (recommended for operator-managed drivers)**

```go
const NUMAListAttributes featuregate.Feature = "NUMAListAttributes"
```

The operator sets `--feature-gates=NUMAListAttributes=true` when it knows the cluster supports list attributes. This is the most explicit approach and avoids version-detection fragility.

### Step 5: Keep your existing vendor-specific attribute (optional but recommended)

During the transition period, publish both:

```go
// Standard attribute (for cross-driver alignment via matchAttribute)
numaAttr, err := deviceattribute.GetNUMANodeAttributeByPCIBusID(pciAddr, listEnabled)
if err == nil {
    attrs[numaAttr.Name] = numaAttr.Value
}

// Vendor-specific attribute (for backward compatibility with existing DeviceClasses/CEL selectors)
attrs["numaNode"] = resourceapi.DeviceAttribute{IntValue: ptr.To(int64(d.NumaNode))}
```

This ensures existing selectors like `device.attributes["gpu.amd.com"].numaNode == 0` keep working while new selectors can use the standardized name for cross-driver matching.

Once all consumers migrate to `resource.kubernetes.io/numaNode`, the vendor-specific attribute can be removed.

## What the List Form Gives You

On a 2-socket, 8-NUMA system (like AMD EPYC with NPS4):

**Scalar form** (`listEnabled=false`):
```
resource.kubernetes.io/numaNode: 0    ← GPU on NUMA 0
resource.kubernetes.io/numaNode: 0    ← NIC on NUMA 0
resource.kubernetes.io/numaNode: 1    ← NIC on NUMA 1
```

`matchAttribute` aligns GPU+NIC only when they're on the exact same NUMA node.

**List form** (`listEnabled=true`):
```
resource.kubernetes.io/numaNode: [0, 1, 2, 3]    ← GPU on NUMA 0, reachable from 1,2,3 (same socket)
resource.kubernetes.io/numaNode: [0, 1, 2, 3]    ← NIC on NUMA 0, reachable from 1,2,3
resource.kubernetes.io/numaNode: [1, 0, 2, 3]    ← NIC on NUMA 1, reachable from 0,2,3
```

`matchAttribute` with list uses set intersection — the GPU (NUMA 0) can pair with the NIC on NUMA 1 because they share reachable nodes `{0,1,2,3}`. This is correct: on the same socket, cross-NUMA access is fast (same SLIT distance). Without the list form, these devices wouldn't be paired even though they have equivalent performance characteristics.

## Per-Driver Adoption Notes

### GPU drivers (AMD, NVIDIA, Intel)

- PCI devices: use `GetNUMANodeAttributeByPCIBusID(pciAddr, listEnabled)`
- Also publish `resource.kubernetes.io/pcieRoot` and `resource.kubernetes.io/pciBusID`
- GPU partitions (MIG, compute partitions): use the parent PF's PCI address for NUMA lookup

### Network drivers (SR-IOV, RDMA)

- VFs: use `GetNUMANodeAttributeByPCIBusID(vfPciAddr, listEnabled)` — VFs inherit the PF's NUMA node
- Also publish `resource.kubernetes.io/pcieRoot` — critical for NIC-GPU co-location on the same PCIe root

### CPU driver

- Use `GetNUMANodeAttribute(numaNode, listEnabled)` — CPUs aren't PCI devices
- Use `deviceattribute.GetNUMANodeForCPU(cpuID)` to find the NUMA node for a CPU core

### Memory driver

- Use `GetNUMANodeAttribute(numaNode, listEnabled)` — memory banks aren't PCI devices

### NVMe driver

- PCI devices: use `GetNUMANodeAttributeByPCIBusID(pciAddr, listEnabled)`

## Summary

| Cluster | What to publish | `listEnabled` |
|---|---|---|
| K8s 1.37+ with `DRAListTypeAttributes=true` | `resource.kubernetes.io/numaNode` as list | `true` |
| K8s 1.37+ with `DRAListTypeAttributes=false` | `resource.kubernetes.io/numaNode` as scalar | `false` |
| K8s 1.33-1.36 | `resource.kubernetes.io/numaNode` as scalar | `false` |

The standardized *name* works on any K8s version with DRA. Only the list *form* requires 1.37+.

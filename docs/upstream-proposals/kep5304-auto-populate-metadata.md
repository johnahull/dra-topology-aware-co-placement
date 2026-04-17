# KEP-5304: Auto-populate device metadata from ResourceSlice attributes

## Component
`k8s.io/dynamic-resource-allocation/kubeletplugin` (Kubernetes upstream)

## Summary

Each DRA driver must manually select which device attributes to include in KEP-5304 metadata (`PrepareResult.Devices[].Metadata.Attributes`). This means every new attribute that a consumer (like KubeVirt) needs requires a code change in every driver that publishes it.

The kubelet plugin framework should automatically copy all device attributes from the ResourceSlice into the KEP-5304 metadata, so consumers get the full attribute set without per-driver changes.

## Problem

Today, each driver manually populates metadata attributes in its `PrepareResourceClaims` implementation:

```go
// GPU driver (driver.go)
attrs["resource.kubernetes.io/pciBusID"] = resourceapi.DeviceAttribute{StringValue: &pci}
attrs["numaNode"] = resourceapi.DeviceAttribute{IntValue: &numa}
// pcieRoot NOT included — driver didn't add it

// NIC driver (dra_hook.go)  
attrs["resource.kubernetes.io/pciBusID"] = resourceapi.DeviceAttribute{StringValue: &pci}
// numaNode NOT included — driver didn't add it
```

The ResourceSlice already has ALL attributes:
```
numaNode, pcieRoot, resource.kubernetes.io/pciBusID, pciAddr, productName, family, ...
```

But the metadata only has whatever the driver explicitly copies. To get `pcieRoot` in the metadata, every driver needs a code change. To get `numaNode` from the NIC driver, the NIC driver needs a code change.

## Proposed Fix

In `kubeletplugin/metadata.go`, when building `DeviceMetadata` from `PrepareResult`, if the driver provides `Metadata.Attributes`, use them. If not (or as a merge), look up the device in the ResourceSlice and copy all its attributes automatically.

```go
// In processPreparedClaim or writeMetadataFile:
if dev.Metadata == nil || len(dev.Metadata.Attributes) == 0 {
    // Auto-populate from ResourceSlice
    sliceAttrs := lookupDeviceAttributes(dev.PoolName, dev.DeviceName)
    dev.Metadata.Attributes = sliceAttrs
}
```

The ResourceSlice data is already available in the kubelet plugin's informer cache.

## Benefits

- **No per-driver changes** when a consumer needs a new attribute
- **All topology attributes** (numaNode, pcieRoot, socket) automatically available
- **Vendor-specific attributes** also available (productName, family, etc.)
- **Backward compatible** — drivers that explicitly set attributes keep their behavior

## Current Impact

| Attribute | GPU driver metadata | NIC driver metadata | ResourceSlice |
|-----------|-------------------|-------------------|---------------|
| `resource.kubernetes.io/pciBusID` | Yes | Yes | Yes |
| `numaNode` | Yes | **No** | Yes |
| `resource.kubernetes.io/pcieRoot` | **No** | **No** | Yes |
| `productName` | Yes | **No** | Yes |

KubeVirt's VEP 115 guest NUMA mapping needs `numaNode` from all drivers. Currently requires per-driver patches or sysfs fallback.

## Related

- KEP-5304: Native Device Metadata API
- KubeVirt VEP 115: PCI NUMA-Aware Topology
- `k8s.io/dynamic-resource-allocation/kubeletplugin/metadata.go`

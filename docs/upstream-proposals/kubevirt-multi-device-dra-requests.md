# KubeVirt: Support Multi-Device DRA Requests in Host Device Passthrough

## Problem Statement

KubeVirt's DRA host device passthrough assumes a 1:1 mapping between a `hostDevices` entry in the VMI spec and a physical device allocated by DRA. When a DRA `ResourceClaim` request has `count > 1` (e.g., 2 GPUs from a single request), the virt-launcher fails with:

```
request "partition-gpu-amd-com" has 2 devices but KubeVirt only supports
exactly one device per request (count > 1 is not supported)
```

This prevents KubeVirt from consuming DRA allocations where multiple devices of the same type are bundled into a single request — a pattern used by the DRA topology coordinator and by users requesting multiple identical devices.

## How It Manifests

### Topology Coordinator Pattern

The DRA topology coordinator creates partition DeviceClasses (e.g., "eighth-machine") that bundle all resources for a machine slice into a single claim. The webhook expands this into sub-requests:

```yaml
# Expanded claim from topology coordinator
spec:
  devices:
    requests:
    - name: partition-gpu-amd-com
      exactly:
        deviceClassName: gpu.amd.com
        count: 2                    # <-- 2 GPUs per eighth
    - name: partition-sriovnetwork-k8snetworkplumbingwg-io
      exactly:
        deviceClassName: sriovnetwork.k8snetworkplumbingwg.io
        count: 2                    # <-- 2 NICs per eighth
```

The VMI spec references these requests:

```yaml
spec:
  domain:
    devices:
      hostDevices:
      - name: gpu0
        claimName: partition-numa0
        requestName: partition-gpu-amd-com     # has 2 devices
```

### Direct User Pattern

A user requesting 4 GPUs for a VM:

```yaml
# ResourceClaim
spec:
  devices:
    requests:
    - name: gpus
      exactly:
        deviceClassName: gpu.amd.com
        count: 4

# VMI
spec:
  domain:
    devices:
      hostDevices:
      - name: gpu-passthrough
        claimName: my-gpus
        requestName: gpus              # has 4 devices
```

## Root Cause

### `resolveDevice()` in `pkg/dra/utils.go`

```go
func resolveDevice(...) (*metadata.Device, error) {
    for _, req := range md.Requests {
        if req.Name == requestName {
            if len(req.Devices) == 0 {
                return nil, fmt.Errorf("request %q has no devices", requestName)
            }
            if len(req.Devices) > 1 {
                // THIS IS THE BLOCKER
                return nil, fmt.Errorf("request %q has %d devices but KubeVirt "+
                    "only supports exactly one device per request", requestName, len(req.Devices))
            }
            return &req.Devices[0], nil
        }
    }
}
```

This function returns a single `*metadata.Device`. All callers (`GetPCIAddressForClaim`, `GetNUMANodeForClaim`, `GetMDevUUIDForClaim`) assume one device per request.

### Host device creation in `converter.go`

The `createDRAGenericHostDevices()` function iterates over `vmi.Spec.Domain.Devices.HostDevices` and calls `GetPCIAddressForClaim()` once per entry. Each entry produces one QEMU `<hostdev>`. There's no mechanism to expand a single `hostDevices` entry into multiple `<hostdev>` elements.

### PCI placement in `pci-placement.go`

The `PlacePCIDevicesWithNUMAAlignment()` function maps PCI addresses to guest NUMA nodes. It expects each address to be known at call time. With multi-device requests, it would need to iterate over all devices in the request and place each one.

## Proposed Solution

### Option A: Expand at VMI spec level (recommended)

The virt-controller should expand multi-device DRA requests into individual `hostDevices` entries before creating the launcher pod. When the virt-controller processes a VMI with:

```yaml
hostDevices:
- name: gpu-passthrough
  claimName: my-claim
  requestName: gpus          # count: 4
```

It should read the allocation result, see 4 devices, and create 4 `hostDevices` entries in the launcher pod spec:

```yaml
hostDevices:
- name: gpu-passthrough-0
  claimName: my-claim
  requestName: gpus
  deviceIndex: 0              # new field: which device in the multi-device request
- name: gpu-passthrough-1
  claimName: my-claim
  requestName: gpus
  deviceIndex: 1
- name: gpu-passthrough-2
  claimName: my-claim
  requestName: gpus
  deviceIndex: 2
- name: gpu-passthrough-3
  claimName: my-claim
  requestName: gpus
  deviceIndex: 3
```

**Pros:** Clean separation — the virt-launcher sees only single-device entries.
**Cons:** Requires a new `deviceIndex` field in the API, and the virt-controller needs to read allocation results (which it currently doesn't for DRA devices).

### Option B: Expand at virt-launcher level

Change `resolveDevice()` to return all devices, and change the host device creation code to iterate over them:

```go
func resolveDevices(...) ([]metadata.Device, error) {
    for _, req := range md.Requests {
        if req.Name == requestName {
            return req.Devices, nil
        }
    }
}
```

In `converter.go`, when processing a `hostDevices` entry with a DRA claim:
1. Call `resolveDevices()` to get all devices in the request
2. Create a `<hostdev>` element for each device
3. Apply NUMA overrides for each device individually

**Pros:** No API changes, all logic in the launcher.
**Cons:** The VMI spec's `hostDevices` list no longer maps 1:1 to guest devices, which may confuse status reporting and device naming.

### Option C: Require users to split requests (current workaround)

Users must create one DRA request per device with `count: 1`:

```yaml
# ResourceClaim with separate requests
spec:
  devices:
    requests:
    - name: gpu-0
      exactly:
        deviceClassName: gpu.amd.com
        count: 1
    - name: gpu-1
      exactly:
        deviceClassName: gpu.amd.com
        count: 1

# VMI
spec:
  domain:
    devices:
      hostDevices:
      - name: gpu0
        claimName: my-claim
        requestName: gpu-0
      - name: gpu1
        claimName: my-claim
        requestName: gpu-1
```

**Pros:** No code changes.
**Cons:** Verbose, doesn't work with topology coordinator partitions (which use a single request per driver), and defeats the purpose of `count` in the DRA API.

## Impact

This issue blocks:

1. **Topology coordinator integration with KubeVirt** — partitions bundle multiple devices per driver into a single request. VMs can't consume partition claims without splitting.

2. **Simple multi-GPU VMs** — users must create N separate requests instead of one request with `count: N`. This is especially painful with alignment constraints (matchAttribute) that need to reference all request names.

3. **Batch GPU workloads** — HPC/AI VMs that need 4-8 GPUs must create 4-8 separate claims or requests, each with its own name, instead of a single `count: 8` request.

## Files to Modify

| File | Change |
|------|--------|
| `pkg/dra/utils.go` | Add `resolveDevices()` returning `[]metadata.Device` |
| `pkg/virt-launcher/virtwrap/converter/converter.go` | Iterate over all devices in multi-device requests when creating `<hostdev>` elements |
| `pkg/virt-launcher/virtwrap/converter/pci-placement.go` | Handle multiple PCI addresses per DRA request in NUMA placement |
| `staging/src/kubevirt.io/api/core/v1/schema.go` | (Option A only) Add `DeviceIndex *int` to `ClaimRequest` |
| `pkg/virt-controller/services/template.go` | (Option A only) Expand multi-device requests in pod spec |

## Real-World Evidence

Observed on Dell XE9680 (8x MI300X GPUs, 2x ConnectX-6 NICs) with K8s 1.36.0-rc.0:

- Topology coordinator creates eighth-machine partitions with `gpu.amd.com: count=2` and `sriovnetwork: count=2`
- KubeVirt VM requesting an eighth partition fails with the multi-device error
- Workaround: use direct claims with `count: 1` per device — this works but bypasses the topology coordinator's partition abstraction

## Recommendation

**Option B** is the most pragmatic for an initial implementation. It requires no API changes and keeps all logic in the virt-launcher where the metadata is available. Option A is cleaner architecturally but requires API evolution and coordination between virt-controller and virt-launcher.

The current workaround (Option C) should be documented in the KubeVirt DRA guide until a proper fix lands.

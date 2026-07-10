# KubeVirt Issue: Allow Multiple hostDevices from Same DRA Request

## Summary

KubeVirt rejects VirtualMachineInstance specs where multiple `hostDevices` entries reference the same `claimName/requestName` pair. This prevents passing multiple GPUs (or NICs) from a single DRA request with `count>1` into a VM.

## Current Behavior

```yaml
spec:
  domain:
    devices:
      hostDevices:
      - name: gpu0
        claimName: my-claim
        requestName: gpu-request   # count=4 in the claim
      - name: gpu1
        claimName: my-claim
        requestName: gpu-request   # REJECTED: duplicate claimName/requestName
```

Error:
```
The request is invalid: spec.domain.devices.hostDevices[1]:
  duplicate claimName/requestName pair "my-claim/gpu-request"
```

## Expected Behavior

Multiple `hostDevices` referencing the same `claimName/requestName` should be allowed when the underlying DRA request has `count>1`. Each hostDevice consumes one device from the request's allocation. The Kubernetes DRA API supports `count>1` — a single request can allocate multiple devices.

## Why This Matters

The DRA topology coordinator generates aggregate DeviceClasses like `half` (half a server's resources) and `full` (entire server). These expand into DRA requests like:

```yaml
requests:
- name: gpu-request
  exactly:
    deviceClassName: gpu.nvidia.com
    count: 8    # 8 GPUs in a full server
```

For pods, this works — the scheduler allocates 8 GPUs from one request. But for VMs, each GPU needs a separate `hostDevice` entry so KubeVirt creates a PCI passthrough device for each. With the current validation, this requires splitting `count=8` into 8 individual `count=1` requests with unique names, which:

1. **Causes DRA scheduler timeout** — 16+ individual requests (8 GPU + 8 NIC) create a combinatorial explosion during device allocation. The scheduler times out trying to evaluate all possible assignments.
2. **Requires complex per-pair alignment constraints** — Instead of one simple `matchAttribute` constraint, the system must generate N per-pair constraints to keep GPU-0 paired with NIC-0, GPU-1 with NIC-1, etc.
3. **Defeats the purpose of `count>1`** — The DRA API supports `count>1` specifically to avoid this overhead.

## Proposed Fix

Remove or relax the duplicate `claimName/requestName` validation in the VMI admission webhook. When a DRA request has `count>1`, allow up to `count` hostDevices to reference the same pair.

### Validation Change

In `pkg/virt-api/webhooks/validating-webhook/admitters/vmi-create-admitter.go` (or equivalent):

```go
// Current: reject any duplicate claimName/requestName
// Proposed: allow duplicates up to the request's count
```

The count can be validated by looking up the referenced ResourceClaim or ResourceClaimTemplate at admission time, or by simply removing the uniqueness check and letting the DRA allocator handle it (it will fail naturally if more hostDevices than allocated devices exist).

### Device Assignment

In `pkg/virt-handler` or `pkg/virt-launcher`, when building the libvirt domain XML, each hostDevice with the same `claimName/requestName` should be assigned a different allocated device from that request's results. The allocation results already contain multiple devices when `count>1`:

```json
{
  "results": [
    {"request": "gpu-request", "driver": "gpu.nvidia.com", "device": "gpu-0"},
    {"request": "gpu-request", "driver": "gpu.nvidia.com", "device": "gpu-1"},
    {"request": "gpu-request", "driver": "gpu.nvidia.com", "device": "gpu-2"},
    {"request": "gpu-request", "driver": "gpu.nvidia.com", "device": "gpu-3"}
  ]
}
```

Each hostDevice entry would consume the next unassigned device from the results with matching `request` name.

## Impact

Without this fix, VMs are limited to partition sizes where each sub-resource has `count=1` (e.g., `eighth` = 1 GPU + 1 NIC). Larger partitions like `half` (4 GPU + 4 NIC) require a workaround that splits requests and adds per-pair constraints, which works but hits scheduler scaling limits at 8+ GPUs.

With this fix, a VM could request `full count=1` and get all 8 GPUs + 8 NICs passed through from a single DRA request — no splitting, no scheduler overhead, no per-pair constraints.

## Test Results Demonstrating the Limitation

On a 2-socket AMD MI355X server (8 GPUs, 8 Pensando NICs):

| DeviceClass | Count | VM Result | Reason |
|-------------|-------|-----------|--------|
| `eighth` | 1 | PASS | 1 GPU + 1 NIC (no count>1) |
| `eighth` | 4 | PASS | 4 × (1 GPU + 1 NIC) with partition-level count |
| `half` | 1 | PASS | 4 GPU + 4 NIC (split into individual requests with per-pair constraints) |
| `half` | 2 | FAIL | 16 split requests → scheduler timeout |
| `full` | 1 | FAIL | 16 split requests → scheduler timeout |

## Related

- DRA `ExactDeviceRequest.Count` field: allows requesting multiple devices in one request
- KubeVirt `GPUsWithDRA` and `HostDevicesWithDRA` feature gates
- Kubernetes DRA scheduler allocation algorithm (separate issue: combinatorial scaling)

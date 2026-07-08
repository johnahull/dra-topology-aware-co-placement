# KubeVirt VFIO Passthrough with DRA Topology Coordinator

Demonstrates a multi-NUMA KubeVirt VM with GPU and NIC VFIO passthrough, using the topology coordinator to automatically align devices to NUMA nodes. The user writes a simple VMI YAML — the webhook auto-generates hostDevices from the partition config.

## What's shown

1. **Host topology** — 8 GPU VFs and 8 NIC VFs across 2 sockets / 8 NUMA nodes
2. **ResourceSlice summary** — 4 DRA drivers publishing 32 devices
3. **Partition DeviceClasses** — topology coordinator aggregates with alignment constraints
4. **VM manifest** — simplified YAML with ResourceClaimTemplate (`numa count=2`) and no hostDevices
5. **Running VM** — `kubectl get vm,vmi` showing Phase=Running
6. **Claim alignment** — `dra-verify.sh claims` showing 2 independent pcieRoot + numaNode alignment groups
7. **Guest NUMA topology** — SSH into VM, `hw-topology.sh` shows 2 NUMA nodes each with its own GPU + NIC

## Key feature: auto-generated hostDevices

The VMI YAML does **not** specify any `hostDevices`. The topology coordinator's webhook:
1. Reads the `ResourceClaimTemplate` to find the DeviceClass (`numa`) and count (`2`)
2. Looks up the `PartitionConfig` to discover passthrough device types (GPU, NIC)
3. Auto-generates 4 `hostDevices` entries (2 GPUs + 2 NICs) with correct expanded request names

The user only writes:
```yaml
resourceClaims:
- name: partitions
  resourceClaimTemplateName: vm-2numa-tpl
```

## Recording

```bash
# Pre-start the VM (boot takes ~90s)
kubectl apply -f demo-vm-2numa.yaml

# Wait for Running
kubectl get vmi demo-vm-2numa

# Record the demo
vhs demo.tape
```

Outputs: `demo.gif`, `demo.mp4`

## Files

| File | Description |
|------|-------------|
| `demo.tape` | VHS recording script |
| `demo-vm-2numa.yaml` | ResourceClaimTemplate + VMI (single file, no hostDevices) |
| `demo-claim-1numa.yaml` | Standalone claim for 1x numa (reference) |
| `demo-claim-2numa.yaml` | Standalone claim for 2x numa (reference) |
| `demo-vmi-1numa.yaml` | VMI with manual hostDevices for 1 numa (reference) |
| `demo-vmi-2numa.yaml` | VMI with manual hostDevices for 2 numa (reference) |
| `show-claim.sh` | Helper: display expanded claim sub-requests and constraints |
| `show-config.sh` | Helper: display PartitionConfig from a DeviceClass |

## Prerequisites

- Kubernetes 1.37+ with DRA enabled
- Topology coordinator deployed with webhook (VMI webhook registered)
- KubeVirt with `GPUsWithDRA` and `HostDevicesWithDRA` feature gates
- GIM loaded with GPU VFs bound to vfio-pci
- SR-IOV operator with `deviceType: vfio-pci` policy (or manual NIC VF vfio-pci binding)
- SR-IOV DRA driver rebuilt with VfConfig global fallback
- Patched virt-launcher (QEMU q35 `pci-hole64-size` fix)
- `dra-verify.sh` and `hw-topology.sh` in PATH (from `testing/scripts/`)
- `sriovnetwork.k8snetworkplumbingwg.io` DeviceClass created
- `sriov-numa-rule` topology rule ConfigMap

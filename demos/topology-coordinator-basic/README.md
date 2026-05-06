# Demo: Topology Coordinator Basic

Demonstrates the topology coordinator computing NUMA-aligned partitions
with CPU, memory, and GPU drivers. Each quarter partition gets 1 GPU,
32 CPUs (shared capacity), and 1 memory device, all on the same NUMA node.

## Prerequisites

- Topology coordinator deployed with ConfigMaps:
  - `gpu-vfio-deviceclass` — maps GPU DeviceClass to `vfio.gpu.nvidia.com`
  - `gpu-numa-mapping` — maps `gpu.nvidia.com/numa` attribute to standard numaNode
- DRA drivers: `dra.cpu` (grouped mode), `dra.memory`, `gpu.nvidia.com`
- NVMe and network drivers stopped (optional — just produces cleaner output)

## Setup ConfigMaps

```bash
kubectl apply -f configmaps.yaml
```

## Run Demo

```bash
# Deploy 3 quarter pods (2 on NUMA 0, 1 on NUMA 1)
kubectl apply -f demo-pods.yaml

# View partition allocation
bash dra-verify.sh deviceclasses
```

## Expected Output

```
quarter · NUMA 0 · pci0000:48 → ...-quarter-numa0  ⚡ demo-pod-1
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-0
quarter · NUMA 0 · pci0000:59 → ...-quarter-numa0  ⚡ demo-pod-2
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-1
quarter · NUMA 1 · pci0000:c7 → ...-quarter-numa1  ⚡ demo-pod-3
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-2
quarter · NUMA 1 · pci0000:d7 → ...-quarter-numa1  free
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-3
```

## Recording

![XE8640 DRA Verification](xe8640-dra-verify.gif)

Re-record with `vhs xe8640-dra-verify.tape`.

## Cleanup

```bash
kubectl delete -f demo-pods.yaml
```

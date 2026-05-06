# Demo: Topology Coordinator Basic

Demonstrates the topology coordinator computing NUMA-aligned partitions
with CPU, memory, and GPU drivers on a Dell XE8640 (4x H100 SXM5, 2 NUMA nodes).

This demo deploys a mixed workload: 1 half partition on NUMA 0 (consuming
2 GPUs, 2 memory devices, and 1 CPU group) and 2 quarter partitions on
NUMA 1 (each consuming 1 GPU, 1 memory device, and 1 CPU group).

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
# Deploy 1 half (NUMA 0) + 2 quarters (NUMA 1)
kubectl apply -f demo-half-and-quarters.yaml

# View partition allocation
dra-verify.sh deviceclasses
```

## Expected Output

```
quarter · NUMA 0 · pci0000:48 → ...-quarter-numa0  ⚡ demo-half-1
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-0
quarter · NUMA 0 · pci0000:59 → ...-quarter-numa0  ⚡ demo-half-1
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-1
quarter · NUMA 1 · pci0000:c7 → ...-quarter-numa1  ⚡ demo-quarter-1
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-2
quarter · NUMA 1 · pci0000:d7 → ...-quarter-numa1  ⚡ demo-quarter-2
  dra.cpu: 1 (32), dra.memory: 1, vfio.gpu.nvidia.com: gpu-vfio-3
half · NUMA 0 → ...-half-numa0  ⚡ demo-half-1
  dra.cpu: 1, dra.memory: 2, vfio.gpu.nvidia.com: 2
half · NUMA 1 → ...-half-numa1  ⚡ demo-quarter-1, demo-quarter-2
  dra.cpu: 1, dra.memory: 2, vfio.gpu.nvidia.com: 2
full → ...-full  ⚡ demo-half-1, demo-quarter-1, demo-quarter-2
  dra.cpu: 2, dra.memory: 4, vfio.gpu.nvidia.com: 4
```

## Recording

![XE8640 DRA Verification](xe8640-dra-verify.gif)

Re-record with `vhs xe8640-dra-verify.tape`.

## Cleanup

```bash
kubectl delete -f demo-half-and-quarters.yaml
```

# Demo: KubeVirt Multi-NUMA VM with DRA

Demonstrates a KubeVirt VM spanning 2 NUMA nodes on a Dell XE8640
(4x H100 SXM5, 2 NUMA nodes). All devices — GPU, CPU, and memory —
are allocated via DRA using topology coordinator partition device classes.

The VM gets one quarter partition from each NUMA node:
- **NUMA 0**: 1 GPU (VFIO), 32 CPUs, hugepages memory
- **NUMA 1**: 1 GPU (VFIO), 32 CPUs, hugepages memory

KubeVirt's `guestMappingPassthrough` mirrors the host NUMA topology
into the guest, so Fedora sees 2 NUMA nodes with the correct CPU and
PCI device affinity.

## Prerequisites

- Topology coordinator deployed with partition device classes
- KubeVirt v1.8.2+ with feature gates: `DRA`, `HostDevicesWithDRA`, `GPUsWithDRA`, `CPUManager`, `ReservedOverheadMemlock`
- DRA drivers: `dra.cpu` (grouped mode), `dra.memory`, `gpu.nvidia.com`
- `virtctl` installed for SSH access to the VM

## Run Demo

```bash
kubectl apply -f demo-vm-2numa.yaml

# Wait for VM to start
kubectl get vmi -w

# Verify NUMA topology inside the guest
dra-verify.sh guest demo-vm
```

## Expected Guest Topology

```
NUMA nodes:
  node0: 0-3 CPUs, 4096 MB
  node1: 4-7 CPUs, 4096 MB

PCI devices with NUMA affinity:
  0000:09:00.0: numa=0  (H100 GPU)
  0000:0c:00.0: numa=1  (H100 GPU)
```

## Cleanup

```bash
kubectl delete -f demo-vm-2numa.yaml
```

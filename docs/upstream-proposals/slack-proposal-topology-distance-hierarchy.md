# Proposal: Topology Distance Hierarchy for DRA — standardize `numaNode` and `socket`

**Goal:** Enable users to co-locate GPU, NIC, CPU, and memory for optimal DMA performance with a single ResourceClaim — no middleware, no driver-specific knowledge, no ConfigMaps.

Without topology-aware placement, device assignment is random. On an 8-GPU node there's a 1-in-8 chance a GPU lands on the same PCIe path as its NIC. Cross-socket placement degrades GPU-NIC throughput by up to 58% with unpredictable variance ([Ojea 2025](https://arxiv.org/abs/2506.23628)). The penalty comes from DMA crossing inter-socket links instead of staying local to the device's memory controller.

Today, `pcieRoot` is the only standard topology attribute, but CPUs and memory don't have one, and only 25% of GPUs share a PCIe switch with a NIC on typical AI hardware. Every driver publishes NUMA under a different name (`gpu.nvidia.com/numa`, `gpu.amd.com/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode`), so `matchAttribute` can't work cross-driver.

**Proposal:** Standardize `resource.kubernetes.io/numaNode` and `resource.kubernetes.io/socket` alongside `pcieRoot`. All three are hardware facts from sysfs. Add `enforcement: preferred` to `matchAttribute`. Users choose the performance level their workload needs:

| Level | Attribute | DMA path | Use case |
|-------|-----------|----------|----------|
| Highest | `pcieRoot` | Within PCIe switch — lowest latency | Real-time inference with GPUDirect RDMA |
| Good | `numaNode` | One hop through root complex — local memory | Multi-GPU training with per-GPU RDMA |
| Acceptable | `socket` | Within socket interconnect — no inter-socket crossing | Dense inference on SNC/NPS hardware |
| None | (no constraint) | May cross inter-socket link — 58% throughput loss | Batch processing where latency doesn't matter |

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: preferred
- matchAttribute: resource.kubernetes.io/socket
  requests: [gpu, nic, cpu, mem]
  enforcement: required
```

Scheduler tries tightest first, relaxes until satisfiable. No single attribute needs to be perfect — the hierarchy handles hardware variation including SNC/NPS.

**Tested on Dell XE9680 (8x MI300X, ConnectX-6, K8s 1.36):** 4-driver pods with GPU+NIC+CPU+memory aligned at each level, both SNC on (4 NUMA nodes) and off (2 NUMA nodes). KubeVirt VMs with correct guest topology via pxb-pcie placement.

Details: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/upstream-proposals/standardize-numanode-and-socket.md

# Proposal: Topology Distance Hierarchy for DRA — standardize `numaNode` and `socket`

**Goal:** Enable users to co-locate GPU, NIC, CPU, and memory for optimal DMA performance with a single ResourceClaim — no middleware, no driver-specific knowledge, no ConfigMaps.

Today, `pcieRoot` is the only standard topology attribute, but CPUs and memory don't have one, and GPUs don't always share a PCIe switch with NICs. Every driver publishes NUMA under a different name (`gpu.nvidia.com/numa`, `gpu.amd.com/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode`), so `matchAttribute` can't work cross-driver.

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

---

**Use cases for each topology level:**

**pcieRoot — same PCIe switch**
Real-time inference with GPUDirect RDMA where per-packet latency matters. Each GPU serves a model, receives input directly from the NIC via RDMA into GPU memory. The extra hop through the root complex for looser coupling is measurable at this scale. Trade-off: constrains which GPUs are usable to only those sharing a switch with a NIC.

**numaNode — same memory controller**
Multi-GPU training with per-GPU RDMA. 4 GPUs + 4 NIC VFs from SR-IOV on the same NUMA node. GPUs are on different PCIe switches but GDR still works — one extra hop through the root complex, all memory local. CPU and memory on the same NUMA handle coordination and data buffers. This is the common case for distributed training.

**socket — same physical package**
Dense multi-tenant inference on SNC/NPS hardware. With SNC-2 enabled, some sub-NUMA nodes have GPUs but no NICs. `numaNode` matching would leave those GPUs without network access. `socket` matching lets every GPU on the socket reach a NIC VF — cross sub-NUMA DMA stays within the socket interconnect, no inter-socket penalty.

**No constraint**
Batch processing where throughput matters but individual request latency doesn't. Use whatever's available.

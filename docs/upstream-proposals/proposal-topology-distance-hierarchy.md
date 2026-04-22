# Proposal: Topology Distance Hierarchy for DRA — standardize `numaNode` and `cpuSocketID`

**Goal:** Enable users to co-locate GPU, NIC, CPU, and memory for optimal DMA performance with a single ResourceClaim

Today, `pcieRoot` is the only standard topology attribute, but CPUs and memory don't have one, and GPUs don't always share a PCIe switch with NICs. Every driver publishes NUMA under a different name (`gpu.nvidia.com/numa`, `gpu.amd.com/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode`), so `matchAttribute` can't work cross-driver.

**Proposal:** Standardize `resource.kubernetes.io/numaNode` and `resource.kubernetes.io/cpuSocketID` alongside `pcieRoot`. All three are hardware facts from sysfs. Add `enforcement: preferred` to `matchAttribute`. Users choose the performance level their workload needs:

| Coupling | Attribute | DMA path | Use case |
|----------|-----------|----------|----------|
| Tight | `pcieRoot` | Within PCIe switch — lowest latency | Real-time inference with GPUDirect RDMA |
| Local | `numaNode` | One hop through root complex — local memory | Multi-GPU training with per-GPU RDMA |
| Near | `cpuSocketID` | Within socket interconnect — no inter-socket crossing | Dense inference on SNC/NPS hardware |
| None | (no constraint) | May cross inter-socket link | Batch processing where latency doesn't matter |

**Example claims for each level:**

Most workloads just need NUMA alignment — one constraint, all four resource types:
```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
```

For tightest GPU↔NIC coupling with CPU/memory local to that switch:
```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
```

For hardware where no single level always works (SNC/NPS), `enforcement: preferred` lets the scheduler try tighter and fall back to looser. This doesn't exist today — it's one of the three changes needed:
```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred        # try same switch, accept if not
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: preferred        # try same NUMA, accept if not (SNC)
- matchAttribute: resource.kubernetes.io/cpuSocketID
  requests: [gpu, nic, cpu, mem]
  enforcement: required         # must be same socket
```

**What's needed upstream:**
1. Standardize `resource.kubernetes.io/numaNode` and `resource.kubernetes.io/cpuSocketID` (sysfs reads, added to `deviceattribute` helper package)
2. All DRA drivers publish them (same two function calls alongside existing `pcieRoot`)
3. `enforcement: preferred` on `matchAttribute` (scheduler tries constraint, relaxes if unsatisfiable)

Note: today `matchAttribute` has no `enforcement` field — constraints are always required. Items 1-2 are valuable without item 3: a single required `numaNode` constraint aligns all four resource types on any hardware where every NUMA has the devices it needs. Item 3 adds the fallback chain for SNC/NPS hardware where `numaNode` is too restrictive.

**Tested on Dell XE9680 (8x MI300X, ConnectX-6, K8s 1.36):** 4-driver pods with GPU+NIC+CPU+memory aligned at each level, both SNC on (4 NUMA nodes) and off (2 NUMA nodes). KubeVirt VMs with correct guest topology via pxb-pcie placement.

Details: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/upstream-proposals/standardize-numanode-and-socket.md
Diagrams: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/diagrams/topology-distance-hierarchy.md

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

Detailed use cases with XE9680 hardware examples and example claims: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/topology-use-cases.md

# Proposal: Standardize `numaNode` for Cross-Driver Topology Alignment in DRA

**Goal:** Enable users to co-locate GPU, NIC, CPU, and memory for optimal DMA performance with a single ResourceClaim

Today, `pcieRoot` is the only standard topology attribute, but CPUs and memory don't have one, and GPUs don't always share a PCIe switch with NICs. Every driver publishes NUMA under a different name (`gpu.nvidia.com/numa`, `gpu.amd.com/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode`), so `matchAttribute` can't work cross-driver.

**Proposal:** Standardize `resource.kubernetes.io/numaNode` alongside `pcieRoot`. Both are hardware facts from sysfs. Add `enforcement: preferred` to `matchAttribute` so the scheduler can try `pcieRoot` first and fall back to `numaNode`.

| Coupling | Attribute | DMA path | Use case |
|----------|-----------|----------|----------|
| Tight | `pcieRoot` | Within PCIe switch — lowest latency | NCCL proxy GPU + NIC, ultra-low-latency inference |
| Local | `numaNode` | One hop through root complex — local memory | Training, inference serving — the critical co-placement boundary |
| None | (no constraint) | May cross inter-socket link | Batch processing where latency doesn't matter |

**Example claims:**

Most workloads just need NUMA alignment — one constraint, all four resource types:
```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
```

For tightest GPU↔NIC coupling with fallback:
```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred        # try same switch, accept if not
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: required         # must be same NUMA
```

**What's needed upstream:**
1. Standardize `resource.kubernetes.io/numaNode` (sysfs read from `/sys/bus/pci/devices/<BDF>/numa_node`, added to `deviceattribute` helper package alongside `pcieRoot` and `pciBusID`)
2. All DRA drivers publish it (one function call alongside existing `pcieRoot`)
3. `enforcement: preferred` on `matchAttribute` (scheduler tries constraint, relaxes if unsatisfiable)

Note: today `matchAttribute` has no `enforcement` field — constraints are always required. Items 1-2 are valuable without item 3: a single required `numaNode` constraint aligns all four resource types on any hardware where every NUMA has the devices it needs. Item 3 adds `pcieRoot` as a preferred constraint for systems where some GPUs share a switch with a NIC and some don't. It's also essential on systems like the Dell R760xa where every PCIe slot has its own root port — `pcieRoot` as a hard constraint would be unsatisfiable, but as `preferred` it gracefully falls through to `numaNode`.

**Why `numaNode`, not `pcieRoot` alone:**
- `pcieRoot` only matches devices that share a PCIe switch. On a Dell XE9680, only 2 of 8 GPUs share a switch with a NIC (25% yield). `numaNode` covers all 8 (100% yield).
- CPUs and memory are not PCI devices — they have no `pcieRoot`. `numaNode` is the only attribute that spans all four resource types.
- On systems where every slot has its own root port (Dell R760xa), `pcieRoot` is unsatisfiable for any GPU+NIC pair. `numaNode` is the only option.

**Why the 58% matters:**
Benchmarks on NVIDIA B200 GPUs with Mellanox RoCE NICs show NUMA-aligned placement achieves 46.93 GB/s vs 29.68 GB/s unaligned — a 58% throughput improvement with near-zero variance ([Ojea 2025](https://arxiv.org/abs/2506.23628)). The difference is between NUMA-aligned and cross-NUMA, not between same-switch and same-NUMA.

**Tested on:**
- **Dell XE9680** (8x MI300X, ConnectX-6, K8s 1.36): 4-driver pods with GPU+NIC+CPU+memory NUMA-aligned. KubeVirt VMs with correct guest topology via pxb-pcie placement.
- **Dell R760xa** (2x NVIDIA A40, ConnectX-7, K8s 1.37-alpha): Every slot has its own root port — `pcieRoot` unsatisfiable, `numaNode` works. Demonstrates why `enforcement: preferred` is essential.
- **Dell XE8640** (4x H100 SXM5, E810 + ConnectX-6 Dx): PCIe switches group GPU+NIC+NVMe — `pcieRoot` works for NCCL proxy GPU selection.

Details: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/upstream-proposals/standardize-numanode.md
Diagrams: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/diagrams/topology-xe9680.md

---

**Use cases:**

**pcieRoot (preferred) — NCCL proxy GPU + NIC on same switch**
Multi-node training where NCCL picks a proxy GPU for inter-node RDMA. The proxy should be on the same PCIe switch as the NIC for lowest DMA latency. The other GPUs relay via NVLink/xGMI. Also applies to ultra-low-latency single-GPU inference.

**numaNode (required) — the critical co-placement boundary**
The right level for most workloads. All GPUs + NIC + CPU + memory on the same NUMA node. Training: 1 shared NIC, NCCL proxy handles RDMA. Inference: 1 VF per pod for network isolation. The 58% throughput gap is between NUMA-aligned and cross-NUMA — the one root complex hop within a NUMA is negligible.

**No constraint — batch processing**
Throughput matters, latency doesn't. Use whatever's available.

Detailed use cases: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/topology-use-cases.md

---

**Note on `cpuSocketID`:**
`cpuSocketID` could serve as an optional fallback on SNC/NPS hardware where sub-NUMA clustering creates NUMA nodes without NICs. However, GPU servers typically run SNC/NPS off, and the recommended approach is to disable SNC for GPU workloads rather than add a scheduler fallback. `cpuSocketID` is not part of this proposal but drivers can publish it independently if needed for specific deployments.

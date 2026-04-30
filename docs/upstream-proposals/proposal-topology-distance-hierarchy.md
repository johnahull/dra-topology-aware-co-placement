# Proposal: Standardize `numaNode` for Cross-Driver Topology Alignment in DRA

**Goal:** Enable users to co-locate GPU, NIC, CPU, and memory for optimal DMA performance with a single ResourceClaim

Today, `pcieRoot` is the only standard topology attribute, but CPUs and memory don't have one, and GPUs don't always share a PCIe switch with NICs. Every driver publishes NUMA under a different name (`gpu.nvidia.com/numa`, `gpu.amd.com/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode`), so `matchAttribute` can't work cross-driver.

This proposal has two parts. Part 1 is the critical change. Part 2 is an optimization that can follow later.

---

## Part 1: Standardize `resource.kubernetes.io/numaNode` (critical)

Standardize `resource.kubernetes.io/numaNode` alongside `pcieRoot`. Both are hardware facts from sysfs.

With a standard `numaNode`, one constraint co-locates all four resource types:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
```

**Why `numaNode` is the critical boundary:**
- Benchmarks show NUMA-aligned placement achieves **46.93 GB/s** vs **29.68 GB/s** unaligned — a **58% throughput improvement** ([Ojea 2025](https://arxiv.org/abs/2506.23628)). This gap is between NUMA-aligned and cross-NUMA, not between same-switch and same-NUMA.
- `pcieRoot` only matches devices on the same PCIe switch — 25% of GPU-NIC pairs on typical hardware. `numaNode` covers 100%.
- CPUs and memory have no `pcieRoot`. `numaNode` is the only attribute that spans all four resource types.
- On systems where every slot has its own root port (Dell R760xa), `pcieRoot` is unsatisfiable for any GPU+NIC pair. `numaNode` is the only option.

**Why `numaNode`, not `pcieRoot` alone:**

| Attribute | GPU+NIC coverage (XE9680) | Includes CPU/memory? |
|-----------|--------------------------|---------------------|
| `pcieRoot` | 2 of 8 (25%) | No |
| `numaNode` | 8 of 8 (100%) | Yes |

**What's needed:**
1. Add `resource.kubernetes.io/numaNode` (int) to the `deviceattribute` library, with a helper: `GetNUMANodeByPCIBusID(pciBusID string) (int, error)`
2. All DRA drivers publish it — one function call alongside existing `pcieRoot`

**Value without Part 2:** A single required `numaNode` constraint aligns all four resource types on any hardware where every NUMA has the devices it needs. This handles the vast majority of real-world deployments — GPU servers run SNC/NPS off by default.

---

## Part 2: `enforcement: preferred` on `matchAttribute` (optimization)

Add an `enforcement` field to `DeviceConstraint` with two values: `Required` (default, current behavior) and `Preferred` (scheduler tries constraint, relaxes if unsatisfiable).

This enables `pcieRoot` as a preferred constraint that falls back to `numaNode`:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred        # try same switch, accept if not
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: required         # must be same NUMA
```

**Arguments for:**
- **Portability** — one claim works on any hardware. On switched systems (XE8640, XE9680), the scheduler picks the GPU sharing a switch with the NIC. On non-switched systems (R760xa), it gracefully falls through to `numaNode`. The workload author doesn't need to know the server model.
- **Non-NCCL workloads** — custom RDMA applications, DPDK networking, or GPU-Direct Storage that don't auto-detect topology. The scheduler is their only chance at optimal placement.
- **Defense in depth** — the scheduler pre-optimizes placement instead of relying on the application to compensate.

**Arguments against:**
- **NCCL/RCCL already handle proxy selection** — both frameworks auto-detect PCIe topology and pick the best proxy GPU regardless of scheduler placement. For AI workloads, the scheduler doing it too is redundant.
- **Minimal real-world benefit** — the performance gain is one root complex hop within a NUMA node. Negligible for training (network round-trip dominates) and inference (millisecond latencies).
- **API complexity** — adding a new field to `DeviceConstraint` requires changes to all 5 K8s binaries (apiserver, scheduler, controller-manager, kubelet, kubectl).

---

## Tested on

- **Dell XE9680** (8x MI300X, ConnectX-6, K8s 1.36): 4-driver pods with GPU+NIC+CPU+memory NUMA-aligned. KubeVirt VMs with correct guest topology via pxb-pcie placement.
- **Dell R760xa** (2x NVIDIA A40, ConnectX-7, K8s 1.37-alpha): Every slot has its own root port — `pcieRoot` unsatisfiable, `numaNode` works. Demonstrates why Part 2 adds value on some hardware.
- **Dell XE8640** (4x H100 SXM5, E810 + ConnectX-6 Dx): PCIe switches group GPU+NIC+NVMe — `pcieRoot` works for NCCL proxy GPU selection.

Details: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/upstream-proposals/standardize-numanode.md
Diagrams: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/diagrams/topology-xe9680.md
Use cases: https://github.com/johnahull/dra-topology-aware-co-placement/blob/main/docs/topology-use-cases.md

---

## Use cases

**numaNode (Part 1) — the critical co-placement boundary**
The right level for most workloads. All GPUs + NIC + CPU + memory on the same NUMA node. Training: 1 shared NIC, NCCL/RCCL proxy handles RDMA. Inference: 1 VF per pod for network isolation. The 58% throughput gap is between NUMA-aligned and cross-NUMA.

**pcieRoot preferred (Part 2) — NCCL proxy GPU + NIC on same switch**
Optimization for systems with PCIe switches. NCCL/RCCL auto-detect this and pick the best proxy anyway — Part 2 pre-optimizes at the scheduler level. Most useful for non-NCCL workloads that don't auto-detect topology.

**No constraint — batch processing**
Throughput matters, latency doesn't. Use whatever's available.

---

**Note on `cpuSocketID`:**
`cpuSocketID` could serve as an optional fallback on SNC/NPS hardware where sub-NUMA clustering creates NUMA nodes without NICs. However, GPU servers typically run SNC/NPS off, and the recommended approach is to disable SNC for GPU workloads rather than add a scheduler fallback. `cpuSocketID` is not part of this proposal but drivers can publish it independently if needed for specific deployments.

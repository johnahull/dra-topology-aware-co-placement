# DRA Topology-Aware Device Co-Placement

**Date:** 2026-04-16

## Goal

Maximize AI/HPC workload performance on Kubernetes by ensuring that GPUs, NICs, CPUs, and memory assigned to a pod or VM are co-located on the same NUMA boundary. Benchmarks on NVIDIA B200 GPUs with Mellanox RoCE NICs show that topologically aligned GPU+NIC placement achieves **46.93 GB/s** on NCCL all_reduce (8 GB messages) versus **29.68 GB/s** unaligned — a **58% throughput improvement** with near-zero variance (±0.04 vs ±6.74 GB/s). The unaligned case suffers not just lower throughput but wildly unpredictable performance, reflecting the "lottery" of random device assignment ([Ojea 2025](https://arxiv.org/abs/2506.23628)). Today, DRA allocates each resource type independently — a GPU may land on NUMA node 0 while its NIC lands on NUMA node 1, with no mechanism to prevent this. This project extends DRA with cross-driver topology awareness to close that gap.

## Why All Four Resource Types Matter

Full NUMA alignment requires co-locating four resource types on the same NUMA node: GPUs, NICs, CPUs, and memory. Aligning only a subset still leaves cross-NUMA data movement in the critical path:

- **GPU + NIC on same NUMA, but CPUs on a different NUMA** — every CPU-GPU transfer (launching kernels, copying buffers) and CPU-NIC transfer (protocol processing) crosses NUMA boundaries
- **GPU + NIC + CPU aligned, but memory on a different NUMA** — the kernel may allocate buffers on a remote NUMA node, adding latency to every memory access

| DRA Driver | Replaces | What It Does |
|-----------|----------|-------------|
| [dra-driver-cpu](https://github.com/kubernetes-sigs/dra-driver-cpu) (kubernetes-sigs) | Kubelet CPU Manager | Exclusive CPU assignment with NUMA/socket/L3 cache topology attributes. Scheduler-visible. |
| [dra-driver-memory](https://github.com/kad/dra-driver-memory) (early development) | Kubelet Memory Manager | Per-NUMA-zone memory and hugepage allocation with NRI-based `cpuset.mems` pinning. |

---

## The Problem

DRA allocates each resource type independently. The `MatchAttribute` constraint only works within a single driver's devices — there is no mechanism to coordinate across the GPU driver, NIC driver, and CPU driver to ensure they all pick devices from the same NUMA node. Without topology-aware placement, GPU assignment is effectively random — on an 8-GPU node, there is only a 1-in-8 chance that a randomly assigned GPU lands on the same PCIe root as the requested NIC ([Ojea 2025](https://arxiv.org/abs/2506.23628)).

See [Gap Analysis](docs/gap-analysis.md) for the detailed technical breakdown of 8 specific gaps.

---

## Solutions

### 1. Topology Coordinator (works today)

A [POC by Fabien Dupont](https://github.com/fabiendupont/k8s-dra-topology-coordinator) — a controller + mutating webhook that solves cross-driver NUMA coordination using only existing Kubernetes APIs:

```
User creates:                        Webhook expands to:
┌──────────────────────────┐         ┌─────────────────────────────────┐
│ ResourceClaim            │         │ ResourceClaim                   │
│   requests:              │         │   requests:                     │
│   - name: partition      │  ────►  │   - name: partition-gpu         │
│     deviceClassName:     │         │     deviceClassName: gpu.nvidia │
│       hgx-b200-quarter   │         │     count: 2                    │
│     count: 1             │         │   - name: partition-rdma        │
└──────────────────────────┘         │     deviceClassName: rdma.mlnx  │
                                     │     count: 1                    │
                                     │   constraints:                  │
                                     │   - matchAttribute: numaNode    │
                                     │     requests: [partition-gpu,   │
                                     │       partition-rdma]           │
                                     └─────────────────────────────────┘
```

See [Topology Coordinator Design](docs/topology-coordinator.md) for architecture, partition levels, and constraint generation modes.

### 2. DRA Driver Changes

Independent driver fixes that must happen regardless of the coordination approach:

| Gap | Driver | Change |
|-----|--------|--------|
| AMD vendor-specific `pciBusID` | AMD GPU DRA | Publish `resource.kubernetes.io/pciBusID` instead of `pciAddr` |
| NVIDIA no NUMA for standard GPUs | NVIDIA GPU DRA | Read `/sys/bus/pci/devices/<BDF>/numa_node` for GPU and MIG types |
| AMD no VFIO passthrough | AMD GPU DRA | Implement VFIO mode for VM passthrough |
| KEP-5304 opt-in | All PCI drivers | Enable metadata API (k8s 1.36+) |

See [Upstream Roadmap](docs/upstream-roadmap.md) for the full 23-patch inventory with status and owners.

### 3. Upstream Standardization (longer-term)

Define `resource.kubernetes.io/numaNode` and cross-driver `MatchAttribute` in the scheduler. There is [active disagreement](docs/topology-attribute-debate.md) about whether `numaNode` should be standardized — sysfs NUMA indices don't reflect real hardware topology under Intel SNC or AMD NPS modes. An alternative approach has CPUs publish `pcieRoot` as a list ([WIP](https://github.com/kubernetes/kubernetes/pull/138297)).

See [Topology Attribute Debate](docs/topology-attribute-debate.md) for the full upstream discussion.

---

## Gap Status Summary

| Gap | Status | Solved By | Phase |
|-----|--------|-----------|-------|
| 1. No standard topology attribute beyond pcieRoot | 🟠 Actively debated — `numaNode` objected to (SNC/NPS concerns), `cpuSocketNumber` also contested, CPUs-publish-pcieRoot-as-list is WIP | Coordinator (now) / Upstream (later) | 1 / 4 |
| 2. No cross-driver constraints | 🟠 Needs KEP work (KEP-5491 does not address this) | Coordinator (now) / Upstream (later) | 1 / 4 |
| 3. AMD vendor-specific `pciBusID` | 🔴 Not started | AMD GPU DRA driver | 2 |
| 4. NVIDIA no NUMA for standard GPUs | 🔴 Not started | NVIDIA GPU DRA driver | 2 |
| 5. AMD no VFIO passthrough | 🔴 Not started | AMD GPU DRA driver | 2 |
| 6. KEP-5304 opt-in | 🟠 NVIDIA in progress | Each PCI DRA driver | 2 |
| 7. KubeVirt placement | 🟠 VEP 115 done, needs coordination | Coordinator + driver gaps | 3 |
| 8. GPU interconnect topology | ⬜ Future | Driver attributes + coordinator | 5 |

---

## Proposed Plan

```mermaid
graph TD
    GOAL["🎯 Cross-driver NUMA<br/>co-placement for<br/>pods and VMs"]

    subgraph "Topology Coordinator (works today)"
        POC_DONE["✅ Coordinator<br/>ConfigMap rules + webhook +<br/>partition abstraction"]
        SOFT_DONE["✅ Soft affinity<br/>preferred enforcement"]
    end

    subgraph "Upstream (longer-term)"
        STD_NUMA["Define standard<br/>resource.k8s.io/numaNode<br/>(KEP-5491 mechanism shipped,<br/>attribute not yet defined)"]
        CROSS_MATCH["Cross-driver<br/>MatchAttribute<br/>in scheduler"]
    end

    subgraph "Driver Gaps"
        NVIDIA_NUMA["NVIDIA: Add numaNode<br/>for standard GPUs & MIG<br/>(read from sysfs)"]
        AMD_VFIO["AMD: Implement VFIO<br/>passthrough mode in<br/>DRA driver"]
        AMD_PCIBUSID["AMD: Publish<br/>resource.k8s.io/pciBusID<br/>(not vendor pciAddr)"]
        KEP5304["All PCI drivers:<br/>KEP-5304 opt-in<br/>(k8s 1.36+)"]
    end

    subgraph "KubeVirt"
        VEP115["VEP 115: PCIe NUMA<br/>topology in guest ✅"]
        KV_DRA["KubeVirt DRA<br/>claim support ✅"]
        KV_FULL["End-to-end<br/>NUMA-aware VMs"]
    end

    POC_DONE --> GOAL
    SOFT_DONE --> POC_DONE
    STD_NUMA --> CROSS_MATCH
    CROSS_MATCH --> GOAL

    NVIDIA_NUMA --> GOAL
    NVIDIA_NUMA -.->|"blocks coordinator<br/>for NVIDIA GPUs"| POC_DONE
    AMD_PCIBUSID --> KEP5304
    AMD_VFIO --> KV_FULL
    KEP5304 --> KV_FULL

    VEP115 --> KV_FULL
    KV_DRA --> KV_FULL
    KV_FULL --> GOAL

    subgraph "Future"
        GPU_TOPO["GPU interconnect topology<br/>NVLink · xGMI"]
    end

    GPU_TOPO -.->|"future"| GOAL

    style GOAL fill:#4a4,color:#fff
    style POC_DONE fill:#4af,color:#fff
    style SOFT_DONE fill:#4af,color:#fff
    style VEP115 fill:#4a4,color:#fff
    style KV_DRA fill:#4a4,color:#fff
    style NVIDIA_NUMA fill:#f44,color:#fff
    style AMD_VFIO fill:#f44,color:#fff
    style AMD_PCIBUSID fill:#f44,color:#fff
    style KEP5304 fill:#fa4,color:#000
    style STD_NUMA fill:#fa4,color:#000
    style CROSS_MATCH fill:#fa4,color:#000
    style KV_FULL fill:#fa4,color:#000
    style GPU_TOPO fill:#ddd,color:#666
```

**Legend:** 🟢 Done  🔵 POC (works today)  🟠 In progress / needs work  🔴 Not started  ⬜ Future

### Phases

1. **NUMA-aligned containers (works now)** — Deploy the topology coordinator with ConfigMap rules. Validates with GPU + NIC + CPU partitions. Provides immediate value for AMD GPUs. Blocked for NVIDIA GPUs until Gap 4 is closed.
2. **Close driver gaps** — NVIDIA NUMA for standard GPUs, AMD `pciBusID` + VFIO, KEP-5304 opt-in for all PCI drivers. Independent changes, can proceed in parallel.
3. **End-to-end NUMA-aware VMs** — Topology coordinator + KEP-5304 + VEP 115 = guest AI frameworks detect GPU-NIC co-locality and enable GPU Direct RDMA.
4. **Upstream standardization** — `resource.kubernetes.io/numaNode` + cross-driver `MatchAttribute`. Coordinator remains valuable for partition abstraction and soft affinity.
5. **GPU interconnect topology (future)** — NVLink / xGMI attributes for intra-node GPU-to-GPU topology.

---

## Relationship to the NUMA Resources Operator

The [NUMA Resources Operator](https://github.com/openshift-kni/numaresources-operator) is the existing OpenShift solution for NUMA-aware scheduling, but for the **device plugin resource model**, not DRA:

| | NUMA Resources Operator | DRA Topology Coordinator |
|---|---|---|
| Resource model | Device plugins + `resources.requests` | DRA ResourceSlices + ResourceClaims |
| Topology data | RTE daemon → NRT CRD | Drivers publish in ResourceSlices directly |
| Scheduling | Secondary scheduler plugin | Mutating webhook + existing DRA allocator |
| DRA awareness | None | Native |

The transition happens as GPU vendors migrate from device plugins to DRA drivers and `dra-driver-cpu` / `dra-driver-memory` reach production maturity.

---

## Documentation

| Document | Description |
|----------|-------------|
| [Gap Analysis](docs/gap-analysis.md) | Detailed technical analysis of 8 gaps, driver comparisons, attribute tables, capability matrix |
| [Topology Attribute Debate](docs/topology-attribute-debate.md) | Upstream numaNode vs pcieRoot vs cpuSocketNumber debate, SNC/NPS problems, worked examples |
| [Architecture](docs/architecture.md) | Component diagrams, hardware layout, allocation flows, Mermaid diagrams |
| [Topology Coordinator Design](docs/topology-coordinator.md) | Partition abstraction, webhook expansion, constraint modes, Solution A (pcieRoot-as-list) |
| [KubeVirt Integration](docs/kubevirt-integration.md) | KEP-5304, VEP 115, VFIO passthrough, guest NUMA topology, test results |
| [Upstream Roadmap](docs/upstream-roadmap.md) | 23 patches across 5 projects with status and upstream actions |
| [Test Results Summary](testing/results/results-summary.md) | Comparison matrix across K8s versions and configurations |
| [Topology Attribute Tradeoffs (diagrams)](testing/diagrams/topology-attribute-tradeoffs.md) | Mermaid visualizations of NPS1, NPS4, SNC cases |

### Upstream Proposals

| Proposal | Description |
|----------|-------------|
| [KEP-5304 Auto-Populate Metadata](docs/upstream-proposals/kep5304-auto-populate-metadata.md) | Kubelet auto-copies ResourceSlice attributes into KEP-5304 metadata |
| [NUMA/SNC/NPS Topology Gap](docs/upstream-proposals/numa-snc-nps-topology-gap.md) | DRA ↔ kubelet topology manager coordination gap |
| [Standardize numaNode with pcieRoot Fallback](docs/upstream-proposals/standardize-numanode-with-pcieroot-fallback.md) | Propose `resource.kubernetes.io/numaNode` as companion to pcieRoot with distance-based fallback |

---

## References

- [KEP-4381: DRA Structured Parameters](https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/4381-dra-structured-parameters/README.md)
- [KEP-5491: List Types for Attributes](https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/5491-dra-list-types-for-attributes) (alpha in v1.36, feature gate `DRAListTypeAttributes`)
- [KEP-5491 implementation PR](https://github.com/kubernetes/kubernetes/pull/137190) (merged 2026-03-21)
- [KEP-5517: DRA for Native Resources](https://github.com/kubernetes/enhancements/pull/5755)
- [DRA driver interoperability tracking](https://github.com/kubernetes-sigs/dra-driver-cpu/issues/56)
- [`cpuSocketNumber` standardization discussion](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564)
- [WIP: `GetPCIeRootAttributeMapFromCPUId` helper](https://github.com/kubernetes/kubernetes/pull/138297)
- [NVIDIA DRA Driver](https://github.com/NVIDIA/k8s-dra-driver-gpu)
- [AMD GPU DRA Driver](https://github.com/ROCm/k8s-gpu-dra-driver)
- [CPU DRA Driver](https://github.com/kubernetes-sigs/dra-driver-cpu) (kubernetes-sigs)
- [Memory DRA Driver](https://github.com/kad/dra-driver-memory) (personal repo, early development)
- [Node Partition Topology Coordinator](https://github.com/fabiendupont/k8s-dra-topology-coordinator) (POC by Fabien Dupont)
- [The Kubernetes Network Driver Model](https://arxiv.org/abs/2506.23628) — GPU/NIC DRA alignment benchmarks (Ojea 2025)
- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)

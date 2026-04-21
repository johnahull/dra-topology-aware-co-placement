# Topology Distance Hierarchy: AI Use Cases

> **TL;DR:** Different AI workloads need different levels of device co-placement. The topology distance hierarchy (pcieRoot → numaNode → socket → node) lets users choose the right trade-off: tighter coupling = better performance but fewer GPUs qualify; looser coupling = all GPUs available but slightly higher DMA latency.

All examples use a Dell XE9680 (2-socket Intel Xeon 6448Y, 8x AMD MI300X GPUs, 2x Mellanox ConnectX-6 Dx NICs, 128 CPUs, ~2 TiB RAM).

---

## Level 1: pcieRoot — Ultra-Low-Latency Inference with GPUDirect RDMA

**Constraint:** GPU and NIC on the same PCIe switch
**DMA path:** GPU → switch → NIC (no root complex hop)

### Use Case

A financial trading or autonomous vehicle inference service where latency matters more than throughput. Each GPU serves a single model, receiving input directly from the network via RDMA into GPU memory — no CPU copy. The GPU processes and sends results back out the same NIC.

### Configuration

- 1 GPU + 1 NIC per partition, same PCIe switch
- Latency: sub-microsecond DMA within the switch
- The extra hop through the root complex for loose coupling (level 2) is measurable and matters for this workload

### XE9680 (SNC off)

| PCIe Root | GPU | NIC | Qualifies? |
|-----------|-----|-----|------------|
| `pci0000:15` | `1b:00.0` | `1d:00.0` | **Yes** |
| `pci0000:37` | `3d:00.0` | — | No |
| `pci0000:48` | `4e:00.0` | — | No |
| `pci0000:59` | `5f:00.0` | — | No |
| `pci0000:97` | `9d:00.0` | `9f:00.0` | **Yes** |
| `pci0000:b7` | `bd:00.0` | — | No |
| `pci0000:c7` | `cd:00.0` | — | No |
| `pci0000:d7` | `dd:00.0` | — | No |

**Yield: 2 of 8 GPUs (25%)**

### Trade-off

You sacrifice 75% of your GPUs to get the lowest-latency DMA path. Only worth it when the latency difference between tight and loose coupling actually matters for the workload.

### Claim

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: required
```

---

## Level 2: numaNode — Multi-GPU Training with Per-GPU RDMA

**Constraint:** GPU and NIC on the same memory controller
**DMA path:** GPU → switch → root complex → switch → NIC (one extra hop, local memory)

### Use Case

An LLM training job where each node runs 4 GPU workers per NUMA node. Each worker does all-reduce over RDMA via its own NIC VF. GPUDirect RDMA sends gradient buffers directly from GPU memory to the NIC. The NIC VFs come from SR-IOV on the physical NICs.

### Configuration

- 4 GPUs + 4 NIC VFs per NUMA node (VFs from the same physical NIC)
- GPUs are on different PCIe switches but the same NUMA — GDR works, one extra hop through the root complex
- CPU on the same NUMA handles coordination (launching kernels, NCCL setup)
- Memory on the same NUMA holds training data buffers
- pcieRoot would only match 1 GPU; numaNode matches all 4

### XE9680 (SNC off)

| NUMA | GPUs | NIC PFs | NIC VFs available | CPUs | Memory |
|------|------|---------|-------------------|------|--------|
| 0 | 4 (1b, 3d, 4e, 5f) | 2 (1d:00.0, 1d:00.1) | 16 | 64 | ~1 TB |
| 1 | 4 (9d, bd, cd, dd) | 2 (9f:00.0, 9f:00.1) | 16 | 64 | ~1 TB |

**Yield: 8 of 8 GPUs (100%)** — 2 training workers, each fully NUMA-local.

### Trade-off

Slightly higher DMA latency than pcieRoot (one root complex hop), but all GPUs are usable. For training workloads where throughput dominates over per-packet latency, this is the right level.

### Claim

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: required
```

---

## Level 3: socket — Dense Inference on SNC/NPS Hardware

**Constraint:** GPU and NIC on the same physical CPU package
**DMA path:** may cross sub-NUMA boundary within the socket, but no inter-socket link

### Use Case

A cloud provider runs 8 independent inference services on one XE9680 with SNC-2 enabled (4 NUMA nodes). Each service gets 1 GPU + 1 NIC VF. But NUMA 1 and 3 have no NICs — requiring `numaNode` matching would leave 4 GPUs without network access.

With `socket` matching, all 4 GPUs per socket can get a NIC VF from the physical NIC on that socket, even if the NIC is on a different sub-NUMA.

### Configuration

- 1 GPU + 1 NIC VF per service, 8 services total
- NIC VFs on NUMA 1/3 come from the NIC on NUMA 0/2 — cross sub-NUMA but same socket
- Sub-NUMA DMA penalty is small (NUMA distance 12 vs 10 on XE9680)

### XE9680 (SNC on, 4 NUMA nodes)

| Socket | NUMA | GPUs | NIC | Cross sub-NUMA? |
|--------|------|------|-----|-----------------|
| 0 | 0 | 2 (1b, 5f) | 2 (1d:00.0, 1d:00.1) | No |
| 0 | 1 | 2 (3d, 4e) | — | Yes (NIC on NUMA 0) |
| 1 | 2 | 2 (9d, dd) | 2 (9f:00.0, 9f:00.1) | No |
| 1 | 3 | 2 (bd, cd) | — | Yes (NIC on NUMA 2) |

**Yield: 8 of 8 GPUs (100%)** — numaNode would only yield 4 (NUMA 0 and 2).

### Trade-off

GPUs on NUMA 1/3 talking to the NIC on NUMA 0/2 cross a sub-NUMA boundary, but stay within the socket. The latency penalty is small compared to crossing sockets. This is the right level when SNC/NPS creates NUMA nodes without NICs.

### Claim

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: preferred          # try NUMA first
- matchAttribute: resource.kubernetes.io/socket
  requests: [gpu, nic, cpu, mem]
  enforcement: required           # fall back to socket
```

---

## Level 4: node — Batch Processing, No Topology Constraint

**Constraint:** none (same machine only)
**DMA path:** may cross inter-socket link (UPI/xGMI)

### Use Case

A nightly batch job processes a queue of images or documents. Throughput matters, latency doesn't. The job uses whatever GPUs and NICs are available. Cross-NUMA is acceptable — the NIC streams data in, GPUs process it, results go to storage.

### Configuration

- No topology constraint — scheduler picks whatever's free
- Maximizes GPU utilization over DMA path optimization

**Yield: 8 of 8 GPUs (100%)**

### Trade-off

Cross-socket DMA can reduce throughput by up to 58% for latency-sensitive workloads ([Ojea 2025](https://arxiv.org/abs/2506.23628)). For batch processing where individual request latency doesn't matter, this is acceptable.

### Claim

```yaml
constraints: []
```

---

## Summary

| Level | Constraint | AI Use Case | GPU:NIC | XE9680 yield (SNC off) | XE9680 yield (SNC on) |
|-------|-----------|-------------|---------|----------------------|---------------------|
| pcieRoot | Same switch | Ultra-low-latency inference with GDR | 1:1 | 2 of 8 (25%) | 2 of 8 (25%) |
| numaNode | Same memory controller | Multi-GPU training with per-GPU RDMA | 4:4 VFs | 8 of 8 (100%) | 4 of 8 (50%) |
| socket | Same package | Dense inference on SNC/NPS hardware | 4:4 VFs | 8 of 8 (100%) | 8 of 8 (100%) |
| node | None | Batch processing | any | 8 of 8 (100%) | 8 of 8 (100%) |

The distance hierarchy lets users choose the right trade-off. The topology coordinator implements levels 1-2 today via the `fallbackAttribute` mechanism. Level 3 requires `socket` as an explicit attribute. Level 4 is the default (no constraints).

## How the Coordinator Maps to This

| Level | Coordinator partition | Coupling label |
|-------|----------------------|----------------|
| pcieRoot | eighth | `tight` |
| numaNode | eighth or quarter | `loose` |
| socket | half | (not yet implemented) |
| node | full | — |

See [Topology Coordinator Design](topology-coordinator.md) and [Topology Attribute Debate](topology-attribute-debate.md#topology-distance-hierarchy) for implementation details.

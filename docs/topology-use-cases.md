# Topology Distance Hierarchy: AI Use Cases

> **TL;DR:** Different AI workloads need different levels of device co-placement. The topology distance hierarchy (pcieRoot → numaNode → socket → node) lets users choose the right trade-off: tight coupling = best performance but fewer GPUs qualify; local/near coupling = all GPUs available but slightly higher DMA latency.

All examples use a Dell XE9680 (2-socket Intel Xeon 6448Y, 8x AMD MI300X GPUs, 2x Mellanox ConnectX-6 Dx NICs, 128 CPUs, ~2 TiB RAM) and Dell XE8640 (2-socket Intel Xeon 6448Y, 4x NVIDIA H100 SXM5 GPUs, ConnectX-6 Dx + E810 NICs).

---

## Level 1: pcieRoot — NCCL Network Proxy with GPUDirect RDMA

**Constraint:** GPU and NIC on the same PCIe switch
**DMA path:** GPU → switch → NIC (no root complex hop)

### Use Case

Multi-node distributed training where NCCL selects a proxy GPU for inter-node communication. NCCL routes inter-node traffic through the GPU that's closest to the NIC — ideally on the same PCIe switch. The other GPUs relay their data to the proxy over NVLink/xGMI (which is 5-10x faster than PCIe), and the proxy sends it out the NIC via GPUDirect RDMA.

Placing the proxy GPU and NIC on the same switch eliminates the root complex hop for every inter-node packet. On large training runs with frequent all-reduce operations, this adds up.

Also applies to ultra-low-latency inference (e.g., financial trading, autonomous vehicles) where a single GPU serves a model and receives input directly from the NIC via RDMA into GPU memory.

### Configuration

- 1 GPU + 1 NIC on the same PCIe switch (the NCCL proxy pair)
- Other GPUs on the same node communicate with the proxy over NVLink/xGMI
- The proxy GPU handles all inter-node RDMA traffic for the node

### XE8640 (4x H100 SXM5)

| PCIe Root | GPU | NIC | Qualifies? |
|-----------|-----|-----|------------|
| `pci0000:48` | `4e:00.0` (H100) | — | No |
| `pci0000:59` | `5f:00.0` (H100) | `5e:00.0` (E810) | **Yes** |
| `pci0000:c7` | `cb:00.0` (H100) | — | No |
| `pci0000:d7` | `db:00.0` (H100) | — | No |

**Yield: 1 of 4 GPUs (25%)** — GPU `5f` is the natural NCCL proxy. The other 3 GPUs reach it via NVLink.

### XE9680 (8x MI300X)

| PCIe Root | GPU | NIC | Qualifies? |
|-----------|-----|-----|------------|
| `pci0000:15` | `1b:00.0` | `1d:00.0` | **Yes** |
| `pci0000:97` | `9d:00.0` | `9f:00.0` | **Yes** |
| (other 6 roots) | GPU only | — | No |

**Yield: 2 of 8 GPUs (25%)**

### When pcieRoot matters vs numaNode

The difference between pcieRoot (same switch, no root complex hop) and numaNode (same NUMA, one root complex hop) is small — measurable in microbenchmarks but typically not the bottleneck. The 58% throughput difference from Ojea 2025 is between NUMA-aligned and **cross-NUMA**, not between same-switch and same-NUMA.

**pcieRoot matters when:**
- Very large training clusters (1000+ GPUs) where shaving microseconds off every all-reduce iteration compounds over millions of iterations
- Ultra-low-latency inference where per-packet latency is the SLA (financial trading, autonomous vehicles)
- GPU-to-NIC microbenchmarks where you're measuring raw DMA bandwidth

**numaNode is sufficient when:**
- Most production training jobs — network round-trip time between nodes dominates, not the intra-node PCIe hop
- Inference serving (vLLM, TGI) — request latency is milliseconds, not microseconds
- Any workload where the NIC is not the hottest path (data loading, checkpointing)

For most users, `numaNode` is the right constraint. NCCL picks the best proxy GPU automatically regardless of whether the constraint is pcieRoot or numaNode.

### Trade-off

You sacrifice 75% of your GPUs to get the lowest-latency DMA path. Only the proxy GPU needs this — the others communicate over NVLink/xGMI. For single-GPU inference, it restricts which GPUs are usable.

On systems like the R760xa where every slot has its own root port, pcieRoot is unsatisfiable for any GPU+NIC pair — `enforcement: Preferred` is required to fall through to numaNode.

### Claim

```yaml
# Prefer pcieRoot, fall back to numaNode if no GPU+NIC share a switch
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: required
```

---

## Level 2: numaNode — Training and Inference with NUMA-Local Devices

**Constraint:** GPU, NIC, CPU, and memory on the same memory controller
**DMA path:** GPU → switch → root complex → switch → NIC (one extra hop, local memory)

### Use Case: Multi-GPU Training

An LLM training job using 4 GPUs per NUMA node. The GPUs communicate with each other over NVLink/xGMI (bypassing PCIe). Inter-node traffic goes through 1-2 NIC VFs via a proxy GPU. All devices need to be NUMA-local because:

- **CPU** launches kernels, coordinates NCCL, and stages training data from storage into host memory — cross-NUMA CPU↔GPU transfers add latency to every batch
- **Memory** holds training data buffers, pinned memory for RDMA — cross-NUMA memory access slows every `cudaMemcpy` and RDMA operation
- **NIC** handles inter-node gradient exchange — GPUDirect RDMA performs best when GPU and NIC share a memory controller
- **NVMe** (if local) feeds training data — CPU reads from NVMe into NUMA-local memory for the data pipeline

pcieRoot would only match the 1 GPU sharing a switch with the NIC. numaNode matches all GPUs on the same NUMA, keeping the entire host-side data path local.

**NIC sharing for training:** A training pod typically needs just 1 NIC (PF or 1-2 VFs) shared across all GPUs on the NUMA node. NCCL funnels all inter-node traffic through a single proxy GPU anyway — the other GPUs relay via NVLink/xGMI. Per-GPU VFs don't help because only the proxy GPU does RDMA directly. A single 100G/200G NIC is rarely the bottleneck for gradient all-reduce.

### Use Case: Multi-Tenant Inference

Multiple independent inference pods on the same NUMA node, each with its own GPU and NIC VF. Unlike training, these pods don't cooperate — they're separate services that each need their own network identity (IP address, RDMA queue pair).

- 4 independent vLLM pods on NUMA 0, each with 1 GPU + 1 NIC VF + CPU + memory
- Each pod gets its own SR-IOV VF from the physical NIC on that NUMA node
- No NVLink between pods — each GPU is isolated

This is where per-GPU VFs matter: not for bandwidth (each VF shares the physical NIC's bandwidth), but for **network isolation** — each pod has its own IP and can be independently routed, load-balanced, and monitored.

### Use Case: Single-GPU Inference Serving

A vLLM or TGI inference pod serving a model on 1 GPU. The pod needs:
- 1 GPU for the model
- 1 NIC (or NIC VF) for client traffic
- CPU cores for tokenization, scheduling, HTTP handling
- Memory for KV cache, request buffers

All on the same NUMA node. This is the most common real-world use case for NUMA co-placement — not ultra-low-latency, just keeping the standard serving path local.

### Configuration

- GPUs + NIC (shared or per-GPU VFs) + CPU + memory on the same NUMA node
- Training: 1 NIC shared across all GPUs, NCCL proxy handles inter-node RDMA
- Multi-tenant inference: 1 VF per GPU for network isolation
- Single-GPU inference: 1 NIC or VF per pod
- GPUs communicate over NVLink/xGMI (not PCIe) for GPU-to-GPU operations

### XE9680 (SNC off)

| NUMA | GPUs | NIC PFs | NIC VFs available | CPUs | Memory |
|------|------|---------|-------------------|------|--------|
| 0 | 4 (1b, 3d, 4e, 5f) | 2 (1d:00.0, 1d:00.1) | 16 | 64 | ~1 TB |
| 1 | 4 (9d, bd, cd, dd) | 2 (9f:00.0, 9f:00.1) | 16 | 64 | ~1 TB |

**Yield: 8 of 8 GPUs (100%)** — 2 NUMA-local groups, each with all resources co-located.

### Trade-off

One root complex hop more than pcieRoot, but all GPUs are usable. This is the right level for the vast majority of AI workloads. The one-hop penalty is negligible compared to network round-trip time (training) or request processing time (inference). The critical gap that numaNode closes is not same-switch vs same-NUMA — it's NUMA-aligned vs cross-NUMA, which is the 58% throughput difference.

### Claims

**Training pod** (4 GPUs + 1 shared NIC, NCCL proxy handles RDMA):
```yaml
requests:
- name: gpu
  exactly: {deviceClassName: gpu.nvidia.com, count: 4}
- name: nic
  exactly: {deviceClassName: dranet, count: 1}
- name: cpu
  exactly: {deviceClassName: dra.cpu, count: 1}
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu]
```

**Multi-tenant inference** (1 GPU + 1 VF per pod, 4 pods on same NUMA):
```yaml
requests:
- name: gpu
  exactly: {deviceClassName: gpu.nvidia.com, count: 1}
- name: nic
  exactly: {deviceClassName: dranet, count: 1}
- name: cpu
  exactly: {deviceClassName: dra.cpu, count: 1}
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu]
```

---

## Level 3: cpuSocketID — Dense Inference on SNC/NPS Hardware

**Constraint:** GPU and NIC on the same physical CPU package
**DMA path:** may cross sub-NUMA boundary within the socket, but no inter-socket link

### Use Case

A cloud provider runs 8 independent inference services on one XE9680 with SNC-2 enabled (4 NUMA nodes). Each service gets 1 GPU + 1 NIC VF. But NUMA 1 and 3 have no NICs — requiring `numaNode` matching would leave 4 GPUs without network access.

With `cpuSocketID` matching, all 4 GPUs per socket can get a NIC VF from the physical NIC on that socket, even if the NIC is on a different sub-NUMA.

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
- matchAttribute: resource.kubernetes.io/cpuSocketID
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

## Level 5: KubeVirt VM — Full Topology in Guest

**Constraint:** same as levels 1-3, plus guest NUMA topology must reflect host placement
**DMA path:** same as the pod-level constraint, with VEP 115 pxb-pcie placement in the guest

### Use Case

A KubeVirt VM running an AI training or inference workload with VFIO-passthrough GPUs and NICs. The VM needs:
- GPU and NIC VFIO-passthrough devices on the same host NUMA node
- vCPUs and memory pinned to the same NUMA node as the devices
- Guest NUMA topology reflecting the host placement — so AI frameworks inside the VM see devices on the correct guest NUMA nodes

Without guest topology, the VM's NCCL/RCCL can't detect GPU-NIC co-locality and may choose suboptimal communication paths.

### Configuration

- DRA allocates GPU + NIC + CPU + memory on the same NUMA (steps 1-3)
- VFIO binds GPU and NIC to `vfio-pci` (step 5)
- KEP-5304 metadata carries PCI addresses and NUMA nodes to virt-launcher (step 6)
- VEP 115 builds guest pxb-pcie topology matching the host placement (step 7)

### Claim

```yaml
# ResourceClaim for GPU + NIC co-located on NUMA 0
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic]

# VM spec with guest NUMA passthrough
spec:
  domain:
    cpu:
      dedicatedCpuPlacement: true
      numa:
        guestMappingPassthrough: {}
    devices:
      hostDevices:
      - claimName: gpu-claim
        name: gpu0
        requestName: gpu
      - claimName: nic-claim
        name: nic0
        requestName: nic
```

### Trade-off

VFIO passthrough gives near-native GPU performance in the VM, but adds complexity: IOMMU groups, locked memory, ACPI configuration, and the full KEP-5304 → VEP 115 chain. Only needed when the workload must run inside a VM (multi-tenancy, security isolation, OpenShift Virtualization).

---

## Summary

| Level | Constraint | AI Use Case | NIC pattern | Yield (SNC off) | Yield (SNC on) |
|-------|-----------|-------------|-------------|-----------------|----------------|
| pcieRoot | Same switch | NCCL proxy GPU + NIC, ultra-low-latency inference | 1 NIC with proxy GPU | 2 of 8 (25%) | 2 of 8 (25%) |
| numaNode | Same memory controller | Training (1 shared NIC), multi-tenant inference (1 VF per GPU), single-GPU serving | Training: 1 NIC shared. Inference: 1 VF per pod | 8 of 8 (100%) | 4 of 8 (50%) |
| cpuSocketID | Same package | Dense inference on SNC/NPS hardware | 8 inference pods on SNC-2 | 8 of 8 (100%) | 8 of 8 (100%) |
| node | None | Batch processing | Nightly image processing | 8 of 8 (100%) | 8 of 8 (100%) |
| VM | numaNode + VEP 115 | AI workloads in KubeVirt VMs | GPU training/inference VM | Same as numaNode | Same as numaNode |

The distance hierarchy lets users choose the right trade-off. `enforcement: preferred` enables the fallback chain: try pcieRoot, fall back to numaNode, floor at cpuSocketID.

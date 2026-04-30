# Topology Distance Hierarchy: AI Use Cases

> **TL;DR:** Different AI workloads need different levels of device co-placement. The two levels that matter are `pcieRoot` (same PCIe switch — tightest, used for NCCL proxy selection) and `numaNode` (same memory controller — the critical co-placement boundary). `enforcement: preferred` on `pcieRoot` with `numaNode` as required gives the best coupling available on any hardware.

All examples use a Dell XE9680 (2-socket Intel Xeon 6448Y, 8x AMD MI300X GPUs, 2x Mellanox ConnectX-6 Dx NICs, 128 CPUs, ~2 TiB RAM) and Dell XE8640 (2-socket Intel Xeon 6448Y, 4x NVIDIA H100 SXM5 GPUs, ConnectX-6 Dx + E810 NICs).

---

## Level 1: pcieRoot — NCCL Network Proxy with GPUDirect RDMA

*Hardware diagrams: [pcieRoot on XE8640](diagrams/use-case-diagrams.md#1-pcieroot--nccl-proxy-xe8640-4x-h100-sxm5), [pcieRoot unsatisfiable on R760xa](diagrams/use-case-diagrams.md#2-pcieroot-unsatisfiable-r760xa-2x-a40)*

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

*Hardware diagrams: [training pod on XE9680](diagrams/use-case-diagrams.md#3-numanode--training-pod-xe9680-8x-mi300x), [multi-tenant inference on XE9680](diagrams/use-case-diagrams.md#4-numanode--multi-tenant-inference-xe9680)*

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

## Level 3: node — Batch Processing, No Topology Constraint

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

## Level 4: KubeVirt VM — Full Topology in Guest

*Hardware diagrams: [single-NUMA VM on R760xa](diagrams/use-case-diagrams.md#5-kubevirt-single-numa-vm-r760xa), [multi-NUMA VM on XE8640](diagrams/use-case-diagrams.md#6-kubevirt-multi-numa-vm-xe8640-4x-h100)*

**Constraint:** same as levels 1-3, plus guest NUMA topology must reflect host placement
**DMA path:** same as the pod-level constraint, with VEP 115 pxb-pcie placement in the guest

### Why VMs Need Guest Topology

AI frameworks inside the VM read `/sys/bus/pci/devices/*/numa_node` to make topology-aware decisions. Without correct guest NUMA topology:

- **NCCL/RCCL** can't detect GPU-NIC co-locality — may pick the wrong RDMA proxy GPU or disable GPUDirect RDMA entirely
- **vLLM** can't pin worker threads to the correct NUMA node — wrong memory allocation decisions
- **Any topology-aware application** sees `numa_node=-1` on all devices and falls back to conservative defaults

DRA places devices correctly on the host, but without the guest topology chain (KEP-5304 → VEP 115 → pxb-pcie), the application inside the VM can't see the placement and makes the same bad decisions it would with random assignment.

### Why Run AI in a VM

- **Multi-tenancy** — cloud providers selling GPU instances to different customers on the same server. VMs give hardware isolation that containers can't provide.
- **Driver version isolation** — different workloads needing different CUDA/ROCm driver versions. Each VM runs its own GPU driver via VFIO passthrough.
- **Security / compliance** — regulated industries requiring VM-level isolation for audit compliance.
- **Legacy migration** — moving existing GPU workloads from VMware/KVM to OpenShift Virtualization without repackaging as containers.

### Use Case: Single-NUMA Inference VM

The typical case — 1-2 GPUs + 1 NIC for inference serving. Everything on one NUMA node, guest sees one NUMA node.

- DRA allocates GPU + NIC + CPU + memory on the same NUMA
- Guest has 1 NUMA node with all devices showing correct `numa_node=0`
- vLLM inside the VM pins threads and allocates memory on NUMA 0

### Use Case: Multi-NUMA Training VM

A larger VM with 4+ GPUs that spans sockets (e.g., all 4 GPUs on the XE8640, which requires both sockets). The guest must see 2 NUMA nodes so NCCL knows which GPUs are local to each other.

- DRA allocates GPUs from both NUMA nodes, NIC on NUMA 0
- Guest has 2 NUMA nodes: NUMA 0 with GPUs + NIC + vCPUs, NUMA 1 with GPUs + vCPUs
- NCCL inside the VM sees the 2-NUMA layout and optimizes communication — uses NVLink for intra-NUMA GPU-to-GPU, picks the NUMA 0 GPU closest to the NIC as the RDMA proxy

Without guest topology, NCCL in a multi-NUMA VM sees all devices as flat — no locality information, suboptimal proxy selection, and may route traffic through the wrong socket.

### Use Case: Full-Node VM

A VM getting all GPUs on the node (e.g., all 8 MI300X on the XE9680). Spans both sockets by definition. Guest topology mirrors the host — 2 NUMA nodes, 4 GPUs per NUMA, NIC per NUMA.

### Configuration

- DRA allocates GPU + NIC + CPU + memory with NUMA constraints (steps 1-3)
- VFIO binds GPU and NIC to `vfio-pci` (step 5)
- KEP-5304 metadata carries PCI addresses and NUMA nodes to virt-launcher (step 6)
- VEP 115 builds guest pxb-pcie topology matching the host placement (step 7)

### Claim

```yaml
# Single-NUMA VM: GPU + NIC on the same NUMA
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic]

# Multi-NUMA VM: GPUs from both NUMAs, NIC on NUMA 0
# (no cross-NUMA constraint — just co-locate NIC with some GPUs)
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu-numa0, nic]

# VM spec (same for both)
spec:
  domain:
    cpu:
      dedicatedCpuPlacement: true
      numa:
        guestMappingPassthrough: {}
    features:
      acpi: {}
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

VFIO passthrough gives near-native GPU performance in the VM, but adds complexity: IOMMU groups, locked memory, ACPI configuration, and the full KEP-5304 → VEP 115 chain. The overhead is only justified when the workload requires VM-level isolation — for workloads that can run in pods, skip straight to levels 1-3.

---

## Summary

| Level | Constraint | AI Use Case | NIC pattern | Yield (SNC off) |
|-------|-----------|-------------|-------------|-----------------|
| pcieRoot | Same switch | NCCL proxy GPU + NIC, ultra-low-latency inference | 1 NIC with proxy GPU | 2 of 8 (25%) |
| numaNode | Same memory controller | Training (1 shared NIC), multi-tenant inference (1 VF per GPU), single-GPU serving | Training: 1 NIC shared. Inference: 1 VF per pod | 8 of 8 (100%) |
| node | None | Batch processing | Any | 8 of 8 (100%) |
| VM (single-NUMA) | numaNode + VEP 115 | Isolated inference (multi-tenancy, driver isolation) | 1-2 GPUs + NIC, single NUMA | Same as numaNode |
| VM (multi-NUMA) | numaNode + VEP 115 | Full-node training, multi-socket VM | All GPUs, spans sockets | All GPUs |

The recommended constraint for most workloads: `pcieRoot` as `enforcement: preferred`, `numaNode` as `enforcement: required`. The scheduler gets the tightest coupling available, and never places devices cross-NUMA.

### Note on cpuSocketID

`cpuSocketID` is an optional attribute that could serve as a fallback on SNC/NPS hardware where `numaNode` is too restrictive (some NUMA nodes have GPUs but no NICs). However, GPU servers typically run with SNC/NPS off, and the right answer for GPU workloads is usually to disable SNC rather than add a scheduler fallback. It is not included in the core proposal but drivers can publish it if needed for specific deployments.

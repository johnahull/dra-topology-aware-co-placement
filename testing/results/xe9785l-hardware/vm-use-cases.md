# XE9785L VM Use Case Configurations

**Hardware:** Dell PowerEdge XE9785L — 8x AMD Instinct MI355X, 2x AMD EPYC 9575F, 3 TB RAM
**NICs:** 8x AMD Pensando Pollara 400G (1:1 with GPU), 2x Mellanox ConnectX-6 Dx (dual-port)
**Platform:** PCIe-only (no NVLink) — IOMMU hardware boundaries provide tenant isolation without a fabric manager

## System Fit

| Use Case | Fit | Why |
|----------|-----|-----|
| 2.1 Shared Inference | **Best** | 3 TB RAM + 128+ CX-6 Dx VFs = most VMs at useful sizes (32 QPX × 48 GB fits in memory) |
| 2.2 Multi-Tenant | Good | Works well, but SMC6216GPU's DPX naturally matches its CX-7 VF count without reconfiguration |
| 2.3 Developer Workbenches | **Best** | Most RAM and most NIC VFs — supports highest developer count |
| 2.4 Mixed Training+Inference | **Best** | Dedicated Pollara PF per GPU for training RDMA (100% pcieRoot yield), CX-6 Dx VFs for inference |

## Hardware Capabilities

| Resource | Partitioning | Modes |
|----------|-------------|-------|
| GPU compute | ROCm compute partition | SPX (whole), DPX (÷2), QPX (÷4), CPX (max) |
| GPU memory | Memory partition | NPS1 (unified), NPS2 (÷2) |
| GPU SR-IOV | GIM (totalvfs=1) | 1 VF per GPU/partition for VFIO passthrough |
| CX-6 Dx NIC | SR-IOV (default 8, configurable) | Up to 252 VFs per PF via `mstconfig` |
| Pollara 400G | SR-IOV (limited) | 1 VF = RDMA capable; 8 VFs = no RDMA |
| BIOS NPS | Nodes Per Socket | NPS1 (2 NUMA), NPS4 (8 NUMA, 1 GPU each) |

**Key constraints:**
- Pollara 400G cards are expensive — use for RDMA only, not general VM networking
- CX-6 Dx VF count (`NUM_OF_VFS`) configurable via `mstconfig` (from `mstflint` RPM), requires reboot
- GPUDirect RDMA not needed for inference VMs — pcieRoot co-placement not required
- Inference VM NIC constraint is numaNode (or even just socket) — intra-socket IOD quadrant distance is negligible
- No NVMe passthrough needed for inference — models load from network storage

---

## 2.1 Shared LLM Inference

**Goal:** Maximum inference density — many models on few GPUs.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS4 | 1 GPU per NUMA, clean memory bandwidth isolation |
| GPU mode | QPX (4 partitions/GPU) | 32 inference slots across 8 GPUs |
| GPU memory | NPS1 per GPU | Each QPX partition gets 1/4 of HBM |
| CX-6 Dx VFs | `NUM_OF_VFS=32` | 1 VF per GPU partition |
| Pollara | Unused | No GPUDirect RDMA needed for inference |
| Hugepages | 1G pages, ~2.8 TB | Pinned VM memory |
| GIM | Enabled | GPU VF passthrough |

**Per-VM:** 1 QPX partition + 1 CX-6 Dx VF + 4 vCPUs + 48 GB RAM
**VM count:** 32

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

---

## 2.2 Multi-Tenant AI Platforms

**Goal:** Predictable per-tenant GPU allocation with hardware isolation. Fewer, larger partitions than 2.1.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS4 | Tenant isolation maps to NUMA boundaries |
| GPU mode | DPX (2 partitions/GPU) | 16 tenant slots — larger partitions for predictable performance |
| GPU memory | NPS2 per GPU | Each DPX partition gets its own HBM domain |
| CX-6 Dx VFs | `NUM_OF_VFS=16` | 1 VF per tenant |
| Pollara | Unused | No RDMA for tenant inference VMs |
| Hugepages | 1G pages, ~2.8 TB | |
| GIM | Enabled | |

**Per-VM:** 1 DPX partition + 1 CX-6 Dx VF + 8 vCPUs + 96 GB RAM
**VM count:** 16

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

---

## 2.3 Developer Workbenches

**Goal:** Maximum user count, smallest viable GPU slice per developer.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS1 | Developers don't need NUMA isolation — simpler config |
| GPU mode | CPX (max partitions/GPU) | Smallest slices, most users |
| GPU memory | NPS2 per GPU | Memory isolation between partitions |
| CX-6 Dx VFs | `NUM_OF_VFS=64` (or match partition count) | 1 VF per developer VM |
| Pollara | Unused | Notebooks don't need RDMA |
| Hugepages | 1G pages, ~2 TB | Smaller VMs, leave more for host |
| GIM | Enabled | |

**Per-VM:** 1 CPX partition + 1 CX-6 Dx VF + 2 vCPUs + 16-32 GB RAM
**VM count:** 32-64 (depends on CPX granularity)

NPS1 is fine here — developers running notebooks aren't latency-sensitive.

```yaml
constraints: []
```

---

## 2.4 Mixed Workloads

**Goal:** Training and inference VMs on the same node. Only use case that needs Pollara RDMA.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS4 | Training needs NUMA-local GPUs; inference needs isolation |
| GPU mode | Mixed per GPU | Training GPUs: SPX. Inference GPUs: QPX |
| CX-6 Dx VFs | `NUM_OF_VFS=16` | Inference VM NICs |
| Pollara | PF or 1-VF on training GPUs | GPUDirect RDMA for NCCL |
| Hugepages | 1G pages, ~2.8 TB | |
| GIM | Enabled | |

**Example split — Socket 0 training, Socket 1 inference:**

| NUMA (NPS4) | GPU | Mode | Pollara | CX-6 Dx | Use |
|-------------|-----|------|---------|---------|-----|
| 0 | `0000:0c:00.0` | SPX | PF (RDMA) | — | Training VM |
| 1 | `0000:3d:00.0` | SPX | PF (RDMA) | — | Training VM |
| 2 | `0000:a8:00.0` | SPX | PF (RDMA) | — | Training VM |
| 3 | `0000:dc:00.0` | SPX | PF (RDMA) | CX-6 Dx (mgmt) | Training VM |
| 4 | `0001:0d:00.0` | QPX (×4) | — | CX-6 Dx VFs | 4 inference VMs |
| 5 | `0001:3d:00.0` | QPX (×4) | — | CX-6 Dx VFs | 4 inference VMs |
| 6 | `0001:a5:00.0` | QPX (×4) | — | CX-6 Dx VFs | 4 inference VMs |
| 7 | `0001:dc:00.0` | QPX (×4) | — | CX-6 Dx VFs | 4 inference VMs |

**Training VM:** 4 SPX GPUs + 4 Pollara PFs (RDMA) + 64 vCPUs + 750 GB RAM — one large VM spanning Socket 0

**Inference VMs:** 16 × (1 QPX partition + 1 CX-6 Dx VF + 4 vCPUs + 48 GB RAM)

```yaml
# Training VM
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu]

# Inference VMs
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

---

## Summary

| Use Case | NPS | GPU Mode | VMs | Pollara | CX-6 Dx VFs | RDMA | pcieRoot constraint |
|----------|-----|----------|-----|---------|-------------|------|---------------------|
| 2.1 Shared Inference | NPS4 | QPX | 32 | Unused | 32 | No | No |
| 2.2 Multi-Tenant | NPS4 | DPX | 16 | Unused | 16 | No | No |
| 2.3 Developer | NPS1 | CPX | 32-64 | Unused | 64 | No | No |
| 2.4 Mixed | NPS4 | SPX + QPX | 1 + 16 | Training only | 16 | Training only | Training only |

**Pattern:** Inference VMs never need Pollara or pcieRoot co-placement. Only training (2.4) uses the RDMA hardware and pcieRoot constraints. The CX-6 Dx cards handle all VM networking — bump `NUM_OF_VFS` to match GPU partition count via `mstconfig`.

## Open Questions

- **GIM + CPX VF count:** Does `sriov_totalvfs` increase when switching from SPX to QPX? If not, only 1 VF per physical GPU regardless of partition count — would limit VM passthrough to 1 partition per GPU.
- **CPX partition IOMMU isolation:** Do individual CPX partitions get separate IOMMU groups for independent VFIO passthrough?
- **AMD GPU DRA driver:** CPX lifecycle management (create/destroy partitions, per-partition ResourceSlice publishing) not yet implemented — needs KEP-4815 Partitionable Devices.

# Supermicro AS-8126GS-TNMR VM Use Case Configurations

**Hardware:** Supermicro AS-8126GS-TNMR — 8x AMD Instinct MI325X, 2x AMD EPYC 9575F, ~1.5 TB RAM
**NICs:** 7x AMD Pensando Pollara 400G (1:1 with 7 GPUs), 1x Mellanox ConnectX-7 IB (root e0, GPU `e5:00.0`)
**Storage:** 6x KIOXIA CD8P NVMe (roots 80/90 have no NVMe)
**Platform:** PCIe-only (no NVLink) — IOMMU hardware boundaries provide tenant isolation without a fabric manager

## System Fit

| Use Case | Fit | Why |
|----------|-----|-----|
| 2.1 Shared Inference | Good | Works, but 1.5 TB RAM limits VM count/size vs XE9785L's 3 TB |
| 2.2 Multi-Tenant | **Best** | DPX (16 partitions) naturally matches CX-7's 16 VFs — zero reconfiguration needed |
| 2.3 Developer Workbenches | Good | Works, but single CX-7 card and 1.5 TB RAM limit scale vs XE9785L |
| 2.4 Mixed Training+Inference | Good | 100% pcieRoot yield for training RDMA, CX-7 VFs for inference — works but fewer VFs than XE9785L |

## Hardware Capabilities

| Resource | Partitioning | Notes |
|----------|-------------|-------|
| GPU compute | ROCm compute partition | SPX, DPX, QPX, CPX (MI325X — same arch as MI300X, likely same modes) |
| GPU memory | Memory partition | NPS1, NPS2 (needs verification on MI325X) |
| GPU SR-IOV | GIM (totalvfs=1) | 1 VF per GPU for VFIO passthrough |
| Pollara 400G (×7) | SR-IOV (1 VF each) | 1 VF = RDMA; multi-VF = no RDMA |
| ConnectX-7 IB (×1) | SR-IOV (16 VFs) | All VFs RDMA capable (IB or Ethernet) |
| NVMe (×6) | SR-IOV (32 VFs each) | Namespace partitioning |
| BIOS NPS | Nodes Per Socket | NPS1 (2 NUMA), NPS4 (8 NUMA, 1 GPU each) |

**Key differences from XE9785L:**
- Only 1 CX-7 card (root e0, Socket 1) vs 2x CX-6 Dx on XE9785L — fewer VFs for VM networking
- Pollara NICs have totalvfs=1 (vs not exposed on XE9785L) — confirmed single-VF only
- NVMe with 32 VFs per drive — storage partitioning available if needed
- CX-7 is InfiniBand-capable (not just Ethernet)
- Only ~1.5 TB RAM (vs 3 TB on XE9785L) — limits VM count/size

---

## 2.1 Shared LLM Inference

**Goal:** Maximum inference density.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS4 | 1 GPU per NUMA |
| GPU mode | QPX (4 partitions/GPU) | 32 inference slots |
| CX-7 VFs | 16 (default) | VM networking — only 1 card limits to 16 VMs with RDMA VFs |
| Pollara | Unused | No RDMA needed for inference |
| Hugepages | 1G pages, ~1.3 TB | |
| GIM | Enabled | |

**Per-VM:** 1 QPX partition + 1 CX-7 VF + 4 vCPUs + 32 GB RAM

**VM count:** 16 (limited by CX-7 VFs, not GPU partitions)

To reach 32 VMs, would need to increase CX-7 `NUM_OF_VFS` via `mstconfig`, or add a second CX-7 card. Without that, 16 of 32 GPU partitions can have network-isolated VFs — remaining partitions would need shared networking.

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

---

## 2.2 Multi-Tenant AI Platforms

**Goal:** Predictable per-tenant allocation with hardware isolation.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS4 | Tenant isolation maps to NUMA |
| GPU mode | DPX (2 partitions/GPU) | 16 tenant slots — matches CX-7 VF count |
| GPU memory | NPS2 per GPU | HBM domain isolation per tenant |
| CX-7 VFs | 16 (default) | 1 VF per tenant — perfect match |
| Pollara | Unused | |
| Hugepages | 1G pages, ~1.3 TB | |
| GIM | Enabled | |

**Per-VM:** 1 DPX partition + 1 CX-7 VF + 8 vCPUs + 64 GB RAM

**VM count:** 16

DPX × 8 GPUs = 16 partitions, CX-7 has 16 VFs — exact match. This is the natural fit for this system.

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

---

## 2.3 Developer Workbenches

**Goal:** Maximum user count.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS1 | Simplicity — developers aren't latency-sensitive |
| GPU mode | CPX (max partitions/GPU) | Smallest slices |
| CX-7 VFs | Increase to 32-64 via `mstconfig` | More developer VMs |
| Pollara | Unused | |
| Hugepages | 1G pages, ~1 TB | Smaller VMs |
| GIM | Enabled | |

**Per-VM:** 1 CPX partition + 1 CX-7 VF + 2 vCPUs + 16 GB RAM

**VM count:** Limited by CX-7 VFs (single card bottleneck) and ~1.5 TB RAM

```yaml
constraints: []
```

---

## 2.4 Mixed Workloads

**Goal:** Training + inference on same node.

| Setting | Value | Why |
|---------|-------|-----|
| NPS mode | NPS4 | |
| GPU mode | Mixed — SPX (training) + QPX (inference) | |
| CX-7 VFs | 16 | Inference VM NICs |
| Pollara | PF on training GPUs | RDMA for NCCL |
| Hugepages | 1G pages, ~1.3 TB | |
| GIM | Enabled | |

**Example split — Socket 0 training, Socket 1 inference:**

| NUMA (NPS4) | GPU | Mode | NIC | Use |
|-------------|-----|------|-----|-----|
| S0-Q0 | `05:00.0` | SPX | Pollara PF (RDMA) | Training |
| S0-Q1 | `15:00.0` | SPX | Pollara PF (RDMA) | Training |
| S0-Q2 | `65:00.0` | SPX | Pollara PF (RDMA) | Training |
| S0-Q3 | `75:00.0` | SPX | Pollara PF (RDMA) | Training |
| S1-Q0 | `85:00.0` | QPX (×4) | CX-7 VFs | 4 inference VMs |
| S1-Q1 | `95:00.0` | QPX (×4) | CX-7 VFs | 4 inference VMs |
| S1-Q2 | `e5:00.0` | QPX (×4) | CX-7 VFs | 4 inference VMs |
| S1-Q3 | `f5:00.0` | QPX (×4) | CX-7 VFs | 4 inference VMs |

**Training VM:** 4 SPX GPUs + 4 Pollara PFs + 64 vCPUs + 375 GB RAM

**Inference VMs:** 16 × (1 QPX partition + 1 CX-7 VF + 4 vCPUs + 24 GB RAM)

The CX-7 being on Socket 1 (root e0) works perfectly here — inference VMs are on Socket 1, CX-7 VFs are local.

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

| Use Case | NPS | GPU Mode | VMs | Pollara | CX-7 VFs | Bottleneck |
|----------|-----|----------|-----|---------|----------|------------|
| 2.1 Shared Inference | NPS4 | QPX | 16 | Unused | 16 | CX-7 VFs (single card) |
| 2.2 Multi-Tenant | NPS4 | DPX | 16 | Unused | 16 | Perfect DPX↔VF match |
| 2.3 Developer | NPS1 | CPX | 32+ | Unused | Increase | CX-7 VFs + RAM |
| 2.4 Mixed | NPS4 | SPX + QPX | 1 + 16 | Training | 16 | CX-7 VFs for inference |

**Key constraint:** Only 1 CX-7 card (16 VFs default). This limits VM networking density compared to the XE9785L (2x CX-6 Dx, 4 ports). For use cases beyond 16 VMs, either increase `NUM_OF_VFS` on the CX-7, swap the one Pollara slot on Socket 1 for a second CX-7, or use container-level networking.

## Open Questions

- **MI325X compute partition modes:** Are SPX/DPX/QPX/CPX available? Same as MI300X or different granularity?
- **MI325X memory partition:** NPS1/NPS2 supported?
- **GIM + CPX VF count:** Does `sriov_totalvfs` increase with compute partitioning?
- **CX-7 max VFs:** Current firmware default is 16 — what's the silicon max? (Likely 256+, configurable via `mstconfig`)

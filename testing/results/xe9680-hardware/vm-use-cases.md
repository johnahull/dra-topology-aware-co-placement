# Dell PowerEdge XE9680 VM Use Case Configurations

**Hardware:** Dell PowerEdge XE9680 — 8x AMD Instinct MI300X, 2x Intel Xeon 6448Y, ~2 TB RAM
**NICs:** 2x Mellanox ConnectX-6 Dx (dual-port, pcieRoot `pci0000:15` on NUMA 0, `pci0000:97` on NUMA 1)
**Storage:** No local NVMe in PCIe topology
**Platform:** PCIe-only (no NVLink), Intel SNC (Sub-NUMA Clustering) instead of AMD NPS

## System Fit

| Use Case | Fit | Why |
|----------|-----|-----|
| 2.1 Shared Inference | Good | No RDMA needed, CX-6 Dx VFs are plenty, 2 TB supports ~24-32 QPX VMs |
| 2.2 Multi-Tenant | Good | numaNode constraint sufficient, all CX-6 Dx VFs support RDMA — simpler NIC config than AMD systems |
| 2.3 Developer Workbenches | Good | 2 TB RAM adequate for dozens of small VMs, no topology constraints needed |
| 2.4 Mixed Training+Inference | **Limited** | Only 25% pcieRoot GPU+NIC yield — NCCL proxy forced to 1 of 4 training GPUs per socket |

## Hardware Capabilities

| Resource | Partitioning | Notes |
|----------|-------------|-------|
| GPU compute | ROCm compute partition | SPX, DPX, QPX, CPX (MI300X Aqua Vanjaram) |
| GPU memory | Memory partition | NPS1 (needs verification for NPS2) |
| GPU SR-IOV | GIM (totalvfs=1) | 1 VF per GPU for VFIO passthrough |
| CX-6 Dx NIC (×2) | SR-IOV | Default 16 VFs per port (configurable via `mstconfig`) |
| BIOS SNC | Sub-NUMA Clustering | Off: 2 NUMA nodes. SNC-2: 4 NUMA nodes |

**Key differences from XE9785L / SMC6216GPU:**
- **Intel CPUs** — SNC instead of AMD NPS. SNC-2 gives 4 NUMA nodes (vs NPS4 = 8)
- **No Pollara NICs** — only CX-6 Dx for all networking (RDMA capable on all VFs)
- **GPU-NIC pcieRoot co-placement:** Only 2 of 8 GPUs share a pcieRoot with a NIC (25% yield)
- **No NVMe** in PCIe topology — all storage is network-attached or RAID
- **No Pensando DPU** — no SmartNIC offload

## Topology (SNC off — 2 NUMA nodes)

| NUMA | GPUs | NIC PFs | pcieRoots |
|------|------|---------|-----------|
| 0 | 4: `1b`, `3d`, `4e`, `5f` | CX-6 Dx `1d:00.0/.1` | `15`, `37`, `48`, `59` |
| 1 | 4: `9d`, `bd`, `cd`, `dd` | CX-6 Dx `9f:00.0/.1` | `97`, `b7`, `c7`, `d7` |

Only GPU `1b:00.0` shares pcieRoot `pci0000:15` with NIC `1d:00.0` (NUMA 0).
Only GPU `9d:00.0` shares pcieRoot `pci0000:97` with NIC `9f:00.0` (NUMA 1).
The other 6 GPUs have no co-located NIC — pcieRoot constraint is 25% yield.

---

## 2.1 Shared LLM Inference

**Goal:** Maximum inference density.

| Setting | Value | Why |
|---------|-------|-----|
| SNC mode | SNC-2 (4 NUMA nodes) | Finer NUMA granularity, 2 GPUs per NUMA |
| GPU mode | QPX (4 partitions/GPU) | 32 inference slots |
| CX-6 Dx VFs | Increase to 32 via `mstconfig` | 1 VF per GPU partition |
| Hugepages | 1G pages, ~1.8 TB | |
| GIM | Enabled | |

**Per-VM:** 1 QPX partition + 1 CX-6 Dx VF + 4 vCPUs + 32 GB RAM

**VM count:** 32

CX-6 Dx has 2 cards × 2 ports = 4 PFs. With `NUM_OF_VFS=32` per port, 128 VFs available — plenty for 32 GPU partitions.

**NIC locality:** Unlike the XE9785L where every GPU has a co-located NIC, here only 2 pcieRoots have NICs. Inference VMs on the other 6 pcieRoots use cross-root NIC VFs — but this doesn't matter since inference doesn't use GPUDirect RDMA. The NIC VFs just need to be on the same NUMA node.

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
| SNC mode | SNC-2 | 4 NUMA nodes, 2 GPUs per NUMA |
| GPU mode | DPX (2 partitions/GPU) | 16 tenant slots |
| CX-6 Dx VFs | 16 (default, 4 ports × 16 = 64 total) | 1 VF per tenant — plenty |
| Hugepages | 1G pages, ~1.8 TB | |
| GIM | Enabled | |

**Per-VM:** 1 DPX partition + 1 CX-6 Dx VF + 8 vCPUs + 64 GB RAM

**VM count:** 16

4 ports × 16 VFs = 64 VFs available for 16 tenants — no VF pressure.

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
| SNC mode | Off (2 NUMA) | Simplicity |
| GPU mode | CPX (max partitions/GPU) | Smallest slices |
| CX-6 Dx VFs | Increase to match partition count | |
| Hugepages | 1G pages, ~1.5 TB | |
| GIM | Enabled | |

**Per-VM:** 1 CPX partition + 1 CX-6 Dx VF + 2 vCPUs + 16 GB RAM

**VM count:** 32-64 (depends on CPX granularity and RAM)

```yaml
constraints: []
```

---

## 2.4 Mixed Workloads

**Goal:** Training + inference on same node.

| Setting | Value | Why |
|---------|-------|-----|
| SNC mode | Off (2 NUMA) | Training VM wants all GPUs on a NUMA node |
| GPU mode | SPX (training) + QPX (inference) | |
| CX-6 Dx VFs | 16 per port | Inference VM NICs |
| Hugepages | 1G pages, ~1.8 TB | |
| GIM | Enabled | |

**Example split — NUMA 0 training, NUMA 1 inference:**

| NUMA | GPU | Mode | NIC | Use |
|------|-----|------|-----|-----|
| 0 | `1b:00.0` | SPX | CX-6 Dx PF `1d:00.0` (RDMA) | Training |
| 0 | `3d:00.0` | SPX | — | Training |
| 0 | `4e:00.0` | SPX | — | Training |
| 0 | `5f:00.0` | SPX | — | Training |
| 1 | `9d:00.0` | QPX (×4) | CX-6 Dx VFs from `9f:00.0` | 4 inference VMs |
| 1 | `bd:00.0` | QPX (×4) | CX-6 Dx VFs | 4 inference VMs |
| 1 | `cd:00.0` | QPX (×4) | CX-6 Dx VFs | 4 inference VMs |
| 1 | `dd:00.0` | QPX (×4) | CX-6 Dx VFs | 4 inference VMs |

**Training VM:** 4 SPX GPUs + 1 CX-6 Dx PF (RDMA, same pcieRoot as GPU `1b`) + 32 vCPUs + 500 GB RAM

**Inference VMs:** 16 × (1 QPX partition + 1 CX-6 Dx VF + 4 vCPUs + 32 GB RAM)

**Training RDMA note:** Only GPU `1b:00.0` shares pcieRoot with the CX-6 Dx — this becomes the NCCL proxy GPU. The other 3 training GPUs relay via xGMI. This is the 25% pcieRoot yield behavior documented in `topology-use-cases.md`.

```yaml
# Training VM
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu]

# Inference VMs
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu]
```

---

## Summary

| Use Case | SNC | GPU Mode | VMs | CX-6 Dx VFs | RDMA | pcieRoot constraint |
|----------|-----|----------|-----|-------------|------|---------------------|
| 2.1 Shared Inference | SNC-2 | QPX | 32 | 32/port | No | No |
| 2.2 Multi-Tenant | SNC-2 | DPX | 16 | 16/port | No | No |
| 2.3 Developer | Off | CPX | 32-64 | Match count | No | No |
| 2.4 Mixed | Off | SPX + QPX | 1 + 16 | 16/port | Training only | Training (preferred, 25% yield) |

**Key constraint:** Only 2 NIC cards, but 4 ports with configurable VFs — no real VF pressure. The limitation is the 25% pcieRoot yield for training RDMA, which is inherent to the XE9680's topology (NICs only on 2 of 8 pcieRoots).

**Advantage over XE9785L for VMs:** All CX-6 Dx VFs support RDMA. No Pollara cards to leave unused. Simpler NIC topology — fewer cards, all VF-capable, all RDMA-capable.

## Open Questions

- **MI300X compute partition modes:** SPX/DPX/QPX/CPX availability and partition counts?
- **GIM + CPX VF count:** Does `sriov_totalvfs` increase with compute partitioning?
- **SNC-2 vs SNC off for VMs:** SNC-2 gives 4 NUMA nodes (2 GPUs each) — better VM-to-NUMA mapping, but halves memory bandwidth per NUMA. Worth it for inference density?
- **CX-6 Dx max VFs:** Default appears to be 16 per port — configurable via `mstconfig` (same as XE9785L)

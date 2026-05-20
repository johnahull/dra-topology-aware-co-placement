# Supermicro AS-8126GS-TNMR — System Summary

**Date:** 2026-05-20
**Hostname:** smc6216gpu
**Platform:** Supermicro AS-8126GS-TNMR
**OS:** RHCOS 9.6 (OpenShift 4.21)

## CPU / NUMA Topology

- **CPU:** 2x AMD EPYC 9575F 64-Core (Turin / Zen 5)
- **Cores:** 128 physical (256 threads)
- **NUMA mode:** NPS1 (1 NUMA node per socket)
- **NUMA node 0 (Socket 0):** CPUs 0-63, 128-191 — 755.5 GB RAM
- **NUMA node 1 (Socket 1):** CPUs 64-127, 192-255 — 755.9 GB RAM
- **Total memory:** ~1.5 TB DDR5
- **L3 cache:** 512 MiB total (16 instances, 32 MiB each)
- **Hugepages:** None allocated

## IOD Quadrant Mapping

Each socket has 1 IOD with 4 quadrants. Each quadrant has its own IOMMU instance (ivhd)
and owns exactly 2 PCIe root complexes — one GPU root and one infrastructure root.
Verified via `/sys/class/iommu/ivhd*/devices/` and `hw-topology.sh --iod`.

**Each quadrant has exactly 1 GPU.**

| Quadrant | IOMMU (ivhd) | GPU Root | Infra Root | GPU BDF | Co-located Devices |
|----------|-------------|----------|------------|---------|-------------------|
| S0-Q0 | ivhd2 | `00` | `30` (empty) | `05:00.0` | POLLARA + NVMe |
| S0-Q1 | ivhd3 | `10` | `20` (USB, SATA) | `15:00.0` | POLLARA + NVMe |
| S0-Q2 | ivhd1 | `60` | `50` (X710, BMC) | `65:00.0` | POLLARA + NVMe |
| S0-Q3 | ivhd0 | `70` | `40` (empty) | `75:00.0` | POLLARA + NVMe |
| S1-Q0 | ivhd6 | `80` | `b0` (empty) | `85:00.0` | POLLARA (no NVMe) |
| S1-Q1 | ivhd7 | `90` | `a0` (USB, SATA) | `95:00.0` | POLLARA (no NVMe) |
| S1-Q2 | ivhd5 | `e0` | `d0` (MegaRAID, CCP) | `e5:00.0` | ConnectX-7 IB + NVMe |
| S1-Q3 | ivhd4 | `f0` | `c0` (I350 GbE) | `f5:00.0` | POLLARA + NVMe |

Data Fabric nodes: `00:18.*` (Socket 0), `00:19.*` (Socket 1) — 8 functions each.

### NPS Mode Impact

| NPS Mode | NUMA Nodes | GPUs per Node | `numaNode` Granularity |
|----------|-----------|---------------|----------------------|
| NPS1 (current) | 2 | 4 | Coarse — same as socket |
| NPS2 | 4 | 2 | Medium — pairs of quadrants |
| NPS4 | 8 | 1 | Fine — matches `pcieRoot` exactly |

## GPU + NIC + NVMe Co-Placement

8x AMD Instinct MI325X (Aqua Vanjaram, PCI 0x1002:0x74a5).
Each GPU sits behind a Broadcom PEX890xx Gen 5 PCIe switch with a co-located NIC and (usually) NVMe.
All accelerator links are **PCIe Gen5 x16**. NVMe links are **Gen5 x4**.

### NUMA 0 — Socket 0 (4 GPUs)

| PCIe Root | GPU BDF | NIC BDF | NIC Type | NVMe BDF | IOMMU (GPU) |
|-----------|---------|---------|----------|----------|-------------|
| `0000:00` | `05:00.0` | `09:00.0` | Pensando POLLARA-1Q400 | `0a:00.0` (KIOXIA CD8P) | 87 |
| `0000:10` | `15:00.0` | `19:00.0` | Pensando POLLARA-1Q400 | `1a:00.0` (KIOXIA CD8P) | 112 |
| `0000:60` | `65:00.0` | `69:00.0` | Pensando POLLARA-1Q400 | `6a:00.0` (KIOXIA CD8P) | 57 |
| `0000:70` | `75:00.0` | `79:00.0` | Pensando POLLARA-1Q400 | `7a:00.0` (KIOXIA CD8P) | 20 |

### NUMA 1 — Socket 1 (4 GPUs)

| PCIe Root | GPU BDF | NIC BDF | NIC Type | NVMe BDF | IOMMU (GPU) |
|-----------|---------|---------|----------|----------|-------------|
| `0000:80` | `85:00.0` | `89:00.0` | Pensando POLLARA-1Q400 | — | 205 |
| `0000:90` | `95:00.0` | `99:00.0` | Pensando POLLARA-1Q400 | — | 228 |
| `0000:e0` | `e5:00.0` | `e6:00.0` | Mellanox ConnectX-7 (IB) | `e7:00.0` (KIOXIA CD8P) | 184 |
| `0000:f0` | `f5:00.0` | `f9:00.0` | Pensando POLLARA-1Q400 | `fa:00.0` (KIOXIA CD8P) | 152 |

### Per-Switch Device Breakdown

Each PEX890xx switch hosts up to 5 downstream devices:

| Downstream Port | Device | Present On |
|----------------|--------|------------|
| `x2:00.0` | GPU (MI325X via AMD bridges) | All 8 roots |
| `x2:01.0` | NIC (Pensando DSC3 or ConnectX-7) | All 8 roots |
| `x2:02.0` | NVMe (KIOXIA CD8P) | 6/8 roots (not 80, 90) |
| `x2:1e.0` | PEX890xx TWC/NT endpoint (switch mgmt) | Roots 00, 70, 80, f0 |
| `x2:1f.0` | Broadcom mpt3sas (SAS controller) | Roots 00, 70, 80, f0 |

### Pensando DSC3 Internal Structure

Each Pensando DSC3 Salina exposes via an internal PCIe switch:

| Function | Class | Driver | IOMMU | Description |
|----------|-------|--------|-------|-------------|
| `x8:00.0` | Processing accel | `tawk_ipc` | Separate | DPU accelerator (Device 1012) |
| `x8:00.1` | Processing accel | none | Separate | DPU function (Device 100f) |
| `x8:00.2` | Processing accel | `pds_core` | Separate | PDS core management |
| `x9:00.0` | Ethernet | `ionic` | Separate | 100/200/400G Ethernet port |

### Infrastructure Roots (no GPU)

| PCIe Root | NUMA | Devices |
|-----------|------|---------|
| `0000:20` | 0 | USB 3.1 xHCI, 2x SATA (AHCI), PCIe dummy function |
| `0000:30` | 0 | Empty |
| `0000:40` | 0 | Empty |
| `0000:50` | 0 | Intel X710 10GbE (2-port), ASMedia SATA, ASPEED BMC VGA, CCP/ASP |
| `0000:a0` | 1 | USB 3.1 xHCI, 2x SATA (AHCI), PCIe dummy function |
| `0000:b0` | 1 | Empty |
| `0000:c0` | 1 | Intel I350 GbE (2-port, management) |
| `0000:d0` | 1 | Broadcom MegaRAID SAS38xx, CCP/ASP |

## SR-IOV Capacity

| Device | NIC Type | Total VFs | Driver |
|--------|----------|-----------|--------|
| Pensando DSC Ethernet (×7) | POLLARA-1Q400 100/200/400G | 1 VF each | `ionic` |
| Pensando DSC Accel (×7) | POLLARA-1Q400 DPU | 1 VF each | `tawk_ipc` |
| ConnectX-7 (`e6:00.0`) | MT2910 InfiniBand | 16 VFs | `mlx5_core` |
| KIOXIA NVMe (×6) | CD8P Gen5 | 32 VFs each | `nvme` |
| Intel X710 (`51:00.0/1`) | 10GBASE-T (mgmt) | 64 VFs/port | `i40e` |
| Intel I350 (`c1:00.0/1`) | 1GbE (mgmt) | 7 VFs/port | `igb` |
| MI325X GPUs (×8) | Aqua Vanjaram | 1 VF each | `amdgpu` |

## IOMMU Isolation

Each GPU is in its own IOMMU group. Pensando DSCs expose 3 processing functions + 1 NIC function, all in separate IOMMU groups. NVMe controllers each get their own group. Full VFIO passthrough is supported without ACS workarounds.

No devices reported `numa_node = -1` (all have proper NUMA affinity).

## matchAttribute Satisfiability

| Constraint | Coverage | Notes |
|------------|----------|-------|
| `pcieRoot` GPU↔NIC | 8/8 (100%) | Every GPU has a co-located NIC |
| `pcieRoot` GPU↔NVMe | 6/8 (75%) | Roots 80, 90 lack NVMe |
| `pcieRoot` GPU↔NIC↔NVMe | 6/8 (75%) | |
| `numaNode` (NPS1) GPU↔NIC | 8/8 (100%) | 4+4 split, coarser than pcieRoot |
| `numaNode` (NPS1) GPU↔NVMe | 6/8 (75%) | Same 2 missing as pcieRoot |
| `numaNode` (NPS4) GPU↔NIC | 8/8 (100%) | 1:1 with pcieRoot |
| `numaNode` (NPS4) GPU↔NVMe | 6/8 (75%) | Same 2 missing as pcieRoot |

## Topology Observations

1. **1 GPU per IOD quadrant.** Verified via `/sys/class/iommu/ivhd*/devices/`: each of the 8 IOMMU instances (4 per socket) owns exactly 1 GPU root. Under NPS4, `matchAttribute: numaNode` would give identical granularity to `matchAttribute: pcieRoot` (1 GPU per group). Under NPS1 (current), `numaNode` is coarser (4 GPUs per group vs 8).

2. **Clean 4+4 NUMA split (NPS1).** No GPU straddles a NUMA boundary. Socket 0 owns roots 00/10/60/70; Socket 1 owns 80/90/e0/f0.

3. **Non-contiguous quadrant roots.** Some quadrants own non-adjacent PCIe roots (e.g., ivhd0 owns roots 40+70, ivhd1 owns roots 50+60). PCIe address proximity does not imply shared IOMMU domain — always verify via ivhd mapping.

4. **Root e0 is the outlier.** Only root with a Mellanox ConnectX-7 InfiniBand HCA instead of a Pensando DSC. The CX-7 has 16 VFs (vs 1 VF per Pensando) and supports both InfiniBand and Ethernet, making it the best candidate for SR-IOV-heavy or RDMA workloads.

5. **VFIO-ready.** All GPUs, NICs, and NVMe devices are in separate IOMMU groups — no ACS issues for DRA device passthrough.

6. **NVMe SR-IOV.** Each KIOXIA CD8P supports 32 VFs, enabling NVMe namespace partitioning via DRA if needed.

7. **Switch management devices.** Roots 00, 70, 80, f0 have additional Broadcom mpt3sas SAS controllers and TWC/NT endpoints for PCIe switch management — these are infrastructure devices, not relevant to DRA scheduling.

# Dell PowerEdge R7725 — System Summary

**Date:** 2026-05-26
**Hostname:** 10.6.131.1 (bare metal, RHEL-based)
**Platform:** Dell PowerEdge R7725
**OS:** Linux (RHEL/Fedora variant)

## CPU / NUMA Topology

- **CPU:** 2x AMD EPYC 9825 144-Core (Turin Dense / Zen 5c)
- **Cores:** 288 physical (576 threads), 12 CCDs per socket
- **NUMA mode:** NPS4 (4 NUMA nodes per socket)
- **Total memory:** ~755 GB DDR5
- **L3 cache:** 768 MiB total (24 instances, 32 MiB each)
- **Hugepages:** None allocated

### NUMA Node Layout (NPS4)

| NUMA | Socket | CPUs | Memory |
|------|--------|------|--------|
| 0 | 0 | 0-35, 288-323 | 94 GB |
| 1 | 0 | 36-71, 324-359 | 95 GB |
| 2 | 0 | 72-107, 360-395 | 94 GB |
| 3 | 0 | 108-143, 396-431 | 95 GB |
| 4 | 1 | 144-179, 432-467 | 95 GB |
| 5 | 1 | 180-215, 468-503 | 95 GB |
| 6 | 1 | 216-251, 504-539 | 95 GB |
| 7 | 1 | 252-287, 540-575 | 94 GB |

### NUMA Distances

| | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-|---|---|---|---|---|---|---|---|
| **Same CCD** | 10 | — | — | — | — | — | — | — |
| **Same socket** | — | 12 | 12 | 12 | — | — | — | — |
| **Cross socket** | — | — | — | — | 32 | 32 | 32 | 32 |

Three distance tiers: 10 (local), 12 (same socket, different quadrant), 32 (cross socket).

### NPS Mode Testing

| Mode | NUMA Nodes | Nodes/Socket | Tested |
|------|-----------|-------------|--------|
| NPS1 | 2 | 1 | Yes — `hw-topology.txt` |
| NPS4 | 8 | 4 | Yes — `hw-topology-nps4.txt` (current) |
| L3-as-NUMA | 24 | 12 | Yes — `hw-topology-l3-numa.txt` |

Under L3-as-NUMA, all same-socket CCDs were equidistant (distance 11) — no quadrant grouping visible. NPS4 exposes quadrant-level distances (12 between quadrants on same socket).

## PCIe Root Complexes

Socket 0 uses PCI domain `0000:`, Socket 1 uses domain `0001:`.

### Socket 0 (Domain 0000)

| Root | IOMMU | Key Devices |
|------|-------|-------------|
| `0000:00` | Yes | BCM57504 4x25G NIC (4 ports) |
| `0000:3e` | — | Empty (dummy bridges) |
| `0000:7a` | Yes | USB 3.1, PCIe dummy |
| `0000:7c` | — | Empty (dummy bridges) |
| `0000:7e` | — | Empty (dummy bridges) |
| `0000:80` | Yes | Marvell BOSS-N1 NVMe, Matrox VGA, Renesas USB 3.0, CCP/ASP |
| `0000:88` | — | Empty (dummy bridges) |
| `0000:c4` | Yes | 4x Samsung PM1745 NVMe (3.2TB each), USB 3.1, 2x SATA |

### Socket 1 (Domain 0001)

| Root | IOMMU | Key Devices |
|------|-------|-------------|
| `0001:00` | Yes | Empty PCIe slots (01-04, GPU expansion) |
| `0001:3e` | — | ConnectX-6 Dx 2-port (mlx5_core, 8 VFs/port) |
| `0001:7a` | Yes | PCIe dummy |
| `0001:7c` | — | Empty |
| `0001:7e` | — | Empty |
| `0001:80` | Yes | CCP/ASP |
| `0001:88` | — | Empty (dummy bridges) |
| `0001:c4` | Yes | BCM57508 2x100G NIC (bnxt_en) |

## IOD Quadrant Mapping

8 IOMMU instances (4 per socket), same structure as Turin Classic. No GPUs installed.
Each quadrant owns 2 PCIe roots.

### NPS4 Quadrant-to-NUMA Mapping

| ivhd | Socket | NUMA (NPS4) | Roots | Key Devices |
|------|--------|-------------|-------|-------------|
| ivhd0 | 0 | 0 | `7e`, `c4` | 4x Samsung PM1745 NVMe, USB, SATA |
| ivhd1 | 0 | 0 | `80`, `88` | Marvell BOSS NVMe, Matrox VGA, USB |
| ivhd2 | 0 | 1 | `00`, `7c` | BCM57504 4x25G NIC |
| ivhd3 | 0 | 2 | `3e`, `7a` | USB 3.1 |
| ivhd4 | 1 | 4 | `7e`, `c4` | BCM57508 2x100G NIC |
| ivhd5 | 1 | 4 | `80`, `88` | CCP/ASP |
| ivhd6 | 1 | 5 | `00`, `7c` | Empty PCIe slots (01-04, GPU expansion) |
| ivhd7 | 1 | 6 | `3e`, `7a` | ConnectX-6 Dx (2-port, 8 VFs/port) |

Data Fabric nodes: `00:18.*` (Socket 0), `00:19.*` (Socket 1) — 8 functions each.

## Network Interfaces

| Interface | NIC Type | BDF | Socket | NUMA (NPS4) | SR-IOV |
|-----------|----------|-----|--------|-------------|--------|
| BCM57504 port 0 | 4x25G OCP3.0 | `0000:01:00.0` | 0 | 1 | — |
| BCM57504 port 1 | 4x25G OCP3.0 | `0000:01:00.1` | 0 | 1 | — |
| BCM57504 port 2 | 4x25G OCP3.0 | `0000:01:00.2` | 0 | 1 | — |
| BCM57504 port 3 | 4x25G OCP3.0 | `0000:01:00.3` | 0 | 1 | — |
| ConnectX-6 Dx port 0 | 25/50/100G | `0001:3f:00.0` | 1 | 6 | 8 VFs |
| ConnectX-6 Dx port 1 | 25/50/100G | `0001:3f:00.1` | 1 | 6 | 8 VFs |
| BCM57508 port 0 | 2x100G QSFP | `0001:c5:00.0` | 1 | 4 | — |
| BCM57508 port 1 | 2x100G QSFP | `0001:c5:00.1` | 1 | 4 | — |

## Storage

| Device | BDF | Socket | NUMA (NPS4) | Type |
|--------|-----|--------|-------------|------|
| Marvell BOSS-N1 | `0000:81:00.0` | 0 | 0 | Boot NVMe (Gen3 x4) |
| Samsung PM1745 | `0000:c5:00.0` | 0 | 0 | 3.2TB NVMe (Gen5 x4) |
| Samsung PM1745 | `0000:c6:00.0` | 0 | 0 | 3.2TB NVMe (Gen5 x4) |
| Samsung PM1745 | `0000:c7:00.0` | 0 | 0 | 3.2TB NVMe (Gen5 x4) |
| Samsung PM1745 | `0000:c8:00.0` | 0 | 0 | 3.2TB NVMe (Gen5 x4) |

## Observations

1. **No GPUs installed.** This is a compute-only R7725 with no accelerators. The empty PCIe slots on Socket 1 (roots `0001:00` slots 01-04) could accommodate GPUs.

2. **Turin Dense (Zen 5c).** The EPYC 9825 is a high-density variant with 144 cores/socket (vs 64 on the 9575F in the SMC6216GPU). Same IOD structure — 4 quadrants per socket, 2 roots per quadrant, 12 CCDs per socket (3 per quadrant).

3. **Dual PCI domains.** Socket 0 uses domain `0000:`, Socket 1 uses `0001:`. This is different from the SMC6216GPU which used a single domain `0000:` with roots `00-f0`.

4. **GPU slots and NICs on different quadrants.** Under NPS4, GPU expansion slots are on NUMA 5 (ivhd6), ConnectX-6 Dx is on NUMA 6 (ivhd7), BCM57508 is on NUMA 4 (ivhd4). DRA `matchAttribute: numaNode` would NOT co-place GPU+NIC — they'd need socket-level affinity.

5. **Storage concentrated on Socket 0, NUMA 0.** All 4 Samsung PM1745 NVMe drives plus the BOSS boot drive are on NUMA 0 (ivhd0/ivhd1). Socket 1 has no storage.

6. **NPS4 confirms quadrant = NUMA node.** Each of the 8 NUMA nodes maps to one IOD quadrant, matching the ivhd instances. However, ivhd0 and ivhd1 both map to NUMA 0, and ivhd4 and ivhd5 both map to NUMA 4 — suggesting some quadrant merging at the NUMA level even under NPS4.

7. **Cross-quadrant NIC placement is a DRA challenge.** If GPUs were installed on Socket 1 NUMA 5, the nearest NIC (ConnectX-6 Dx on NUMA 6) is distance 12 — same socket but different quadrant. This makes `pcieRoot` the more accurate co-placement constraint than `numaNode` on this board layout.

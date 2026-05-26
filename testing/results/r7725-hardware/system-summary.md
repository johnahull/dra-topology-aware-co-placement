# Dell PowerEdge R7725 — System Summary

**Date:** 2026-05-26
**Hostname:** 10.6.131.1 (bare metal, RHEL-based)
**Platform:** Dell PowerEdge R7725
**OS:** Linux (RHEL/Fedora variant)

## CPU / NUMA Topology

- **CPU:** 2x AMD EPYC 9825 144-Core (Turin Dense / Zen 5c)
- **Cores:** 288 physical (576 threads)
- **NUMA mode:** NPS1 (1 NUMA node per socket)
- **NUMA node 0 (Socket 0):** CPUs 0-143, 288-431 — 377 GB RAM
- **NUMA node 1 (Socket 1):** CPUs 144-287, 432-575 — 378 GB RAM
- **Total memory:** ~755 GB DDR5
- **L3 cache:** 768 MiB total (24 instances, 32 MiB each)
- **Hugepages:** None allocated

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
| `0001:00` | Yes | Empty PCIe slots (01-04) |
| `0001:3e` | — | ConnectX-6 Dx 2-port (mlx5_core, 8 VFs/port) |
| `0001:7a` | Yes | PCIe dummy |
| `0001:7c` | — | Empty |
| `0001:7e` | — | Empty |
| `0001:80` | Yes | CCP/ASP |
| `0001:88` | — | Empty (dummy bridges) |
| `0001:c4` | Yes | BCM57508 2x100G NIC (bnxt_en) |

## IOD Quadrant Mapping

8 IOMMU instances (4 per socket), same structure as Turin Classic. No GPUs installed.

| ivhd | Socket | Roots | Key Devices |
|------|--------|-------|-------------|
| ivhd0 | 0 | `7e`, `c4` | 4x Samsung PM1745 NVMe, USB, SATA |
| ivhd1 | 0 | `80`, `88` | Marvell BOSS NVMe, Matrox VGA, USB |
| ivhd2 | 0 | `00`, `7c` | BCM57504 4x25G NIC |
| ivhd3 | 0 | `3e`, `7a` | USB 3.1 |
| ivhd4 | 1 | `7e`, `c4` | BCM57508 2x100G NIC |
| ivhd5 | 1 | `80`, `88` | CCP/ASP |
| ivhd6 | 1 | `00`, `7c` | Empty PCIe slots (01-04) |
| ivhd7 | 1 | `3e`, `7a` | ConnectX-6 Dx (2-port, 8 VFs/port) |

Data Fabric nodes: `00:18.*` (Socket 0), `00:19.*` (Socket 1) — 8 functions each.

## Network Interfaces

| Interface | NIC Type | BDF | Socket | SR-IOV |
|-----------|----------|-----|--------|--------|
| BCM57504 port 0 | 4x25G OCP3.0 | `0000:01:00.0` | 0 | — |
| BCM57504 port 1 | 4x25G OCP3.0 | `0000:01:00.1` | 0 | — |
| BCM57504 port 2 | 4x25G OCP3.0 | `0000:01:00.2` | 0 | — |
| BCM57504 port 3 | 4x25G OCP3.0 | `0000:01:00.3` | 0 | — |
| ConnectX-6 Dx port 0 | 25/50/100G | `0001:3f:00.0` | 1 | 8 VFs |
| ConnectX-6 Dx port 1 | 25/50/100G | `0001:3f:00.1` | 1 | 8 VFs |
| BCM57508 port 0 | 2x100G QSFP | `0001:c5:00.0` | 1 | — |
| BCM57508 port 1 | 2x100G QSFP | `0001:c5:00.1` | 1 | — |

## Storage

| Device | BDF | Socket | Type |
|--------|-----|--------|------|
| Marvell BOSS-N1 | `0000:81:00.0` | 0 | Boot NVMe (Gen3 x4) |
| Samsung PM1745 | `0000:c5:00.0` | 0 | 3.2TB NVMe (Gen5 x4) |
| Samsung PM1745 | `0000:c6:00.0` | 0 | 3.2TB NVMe (Gen5 x4) |
| Samsung PM1745 | `0000:c7:00.0` | 0 | 3.2TB NVMe (Gen5 x4) |
| Samsung PM1745 | `0000:c8:00.0` | 0 | 3.2TB NVMe (Gen5 x4) |

## Observations

1. **No GPUs installed.** This is a compute-only R7725 with no accelerators. The empty PCIe slots on Socket 1 (roots `0001:00` slots 01-04) could accommodate GPUs.

2. **Turin Dense (Zen 5c).** The EPYC 9825 is a high-density variant with 144 cores/socket (vs 64 on the 9575F in the SMC6216GPU). Same IOD structure — 4 quadrants per socket, 2 roots per quadrant.

3. **Dual PCI domains.** Socket 0 uses domain `0000:`, Socket 1 uses `0001:`. This is different from the SMC6216GPU which used a single domain `0000:` with roots `00-f0`.

4. **All NICs on different sockets.** BCM57504 (4x25G) is on Socket 0; ConnectX-6 Dx and BCM57508 (2x100G) are on Socket 1. No NIC co-location opportunity within a single PCIe root.

5. **Storage concentrated on Socket 0.** All 4 Samsung PM1745 NVMe drives plus the BOSS boot drive are on Socket 0. Socket 1 has no storage.

6. **PCIe slots available for GPU expansion.** Socket 1 root `0001:00` has 4 empty downstream bridges (slots 01-04), suggesting GPU tray support.

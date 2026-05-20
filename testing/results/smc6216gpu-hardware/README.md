# Supermicro AS-8126GS-TNMR — Hardware Topology

**Hostname:** smc6216gpu
**Date collected:** 2026-05-20
**OS:** RHCOS 9.6 (OpenShift 4.21)

## System Topology Diagram

Open [`topology.excalidraw`](topology.excalidraw) in [excalidraw.com](https://excalidraw.com) for an interactive view, or see the exported SVG:

![PCIe / NUMA Topology](topology.svg)

## Quick Reference

| | Socket 0 (NUMA 0) | Socket 1 (NUMA 1) |
|---|---|---|
| **CPU** | AMD EPYC 9575F, 64c/128t | AMD EPYC 9575F, 64c/128t |
| **CPUs** | 0-63, 128-191 | 64-127, 192-255 |
| **GPUs** | 4x MI325X (roots 00/10/60/70) | 4x MI325X (roots 80/90/e0/f0) |
| **NICs** | 4x Pensando DSC | 3x Pensando DSC + 1x ConnectX-7 |
| **NVMe** | 4x KIOXIA CD8P | 2x KIOXIA CD8P (roots 80/90 empty) |

## Co-Placement Coverage

For DRA topology-aware scheduling with `matchAttribute`:

| Constraint | GPU↔NIC | GPU↔NVMe | GPU↔NIC↔NVMe |
|------------|---------|----------|--------------|
| `pcieRoot` | 8/8 (100%) | 6/8 (75%) | 6/8 (75%) |
| `numaNode` | 8/8 (100%) | 6/8 (75%) | 6/8 (75%) |

On this system, `pcieRoot` and `numaNode` produce identical co-placement results because each PCIe root maps to exactly one NUMA node with one GPU. However, `pcieRoot` is the finer constraint (8 groups vs 2).

## Files

| File | Description |
|------|-------------|
| [`system-summary.md`](system-summary.md) | Full hardware inventory with BDFs, IOMMU groups, SR-IOV |
| [`numa-topology.txt`](numa-topology.txt) | Full NUMA-aware PCIe topology with drivers, IOMMU groups, SR-IOV, link speeds |
| [`pcie-tree.txt`](pcie-tree.txt) | Raw `lspci -tv` output |
| [`topology.excalidraw`](topology.excalidraw) | Interactive diagram (drag into excalidraw.com) |
| [`topology.svg`](topology.svg) | Exported SVG of the topology diagram |

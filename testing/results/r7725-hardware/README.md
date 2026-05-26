# Dell PowerEdge R7725 — Hardware Topology

**Address:** 10.6.131.1
**Date collected:** 2026-05-26

## Quick Reference

| | Socket 0 (NUMA 0) | Socket 1 (NUMA 1) |
|---|---|---|
| **CPU** | AMD EPYC 9825 144c/288t (Zen 5c) | AMD EPYC 9825 144c/288t (Zen 5c) |
| **CPUs** | 0-143, 288-431 | 144-287, 432-575 |
| **PCI Domain** | `0000:` | `0001:` |
| **GPUs** | — | — (4 empty slots) |
| **NICs** | BCM57504 4x25G | CX-6 Dx + BCM57508 2x100G |
| **NVMe** | 4x Samsung PM1745 3.2TB + BOSS boot | — |

## Notes

- No GPUs installed — compute-only configuration
- Turin Dense (Zen 5c) with same IOD quadrant structure as Turin Classic
- Dual PCI domains (one per socket) unlike single-domain SMC6216GPU
- 4 empty PCIe slots on Socket 1 for potential GPU expansion

## Files

| File | Description |
|------|-------------|
| [`system-summary.md`](system-summary.md) | Full hardware inventory with IOD quadrants, NICs, storage |
| [`hw-topology.txt`](hw-topology.txt) | hw-topology.sh output with PCIe tree and IOD mapping |
| [`pcie-tree.txt`](pcie-tree.txt) | Raw `lspci -tv` output |
| [`lscpu.txt`](lscpu.txt) | CPU topology and features |
| [`iommu-df.txt`](iommu-df.txt) | IOMMU instances and Data Fabric nodes |
| [`numa-memory.txt`](numa-memory.txt) | NUMA memory and node distances |

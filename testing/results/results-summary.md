# Test Results Summary

**Date:** 2026-04-09 through 2026-04-17
**Hardware:** Dell XE9680 (2-socket Intel Xeon 6448Y, 8x AMD MI300X GPUs, 2x Mellanox ConnectX-6 Dx NICs, 128 CPUs, ~2 TiB RAM)

## Test Progression

| Test | Platform | K8s | Drivers | Result | Date |
|------|----------|-----|---------|--------|------|
| 3-driver NUMA isolation | OCP 4.21 | 1.34.5 | GPU, NIC, CPU | 4-pod quarter split, zero cross-NUMA | 2026-04-09 |
| KubeVirt GPU+NIC VFIO | OCP 4.21 | 1.34.5 | GPU, NIC | VM with 2 guest NUMA nodes (VEP 115) | 2026-04-14 |
| 4-driver full stack | Fedora 43 | 1.36.0-rc.0 | GPU, NIC, CPU, Memory | Quarter + half splits, DRAConsumableCapacity | 2026-04-14 |
| KubeVirt GPU VFIO via DRA | Fedora 43 | 1.36.0-rc.0 | GPU, NIC | KEP-5304 native metadata, VFIO passthrough | 2026-04-14 |
| Topology coordinator partitions | Fedora 43 | 1.36.0-rc.0 | GPU, NIC, CPU, Memory | 8-pod eighth-machine split, webhook expansion | 2026-04-14/15 |
| Full GPU+NIC VFIO with guest NUMA | Fedora 43 | 1.36.0-rc.0 | GPU, NIC | GIM SR-IOV VFs, 7 KubeVirt patches, VEP 115 fix | 2026-04-15/16 |
| Hardware topology capture (SNC on) | Fedora 43 | 1.36.0-rc.0 | All 4 | 4 NUMA, 9 DeviceClasses (4 tight + 4 loose + 1 full) | 2026-04-17 |
| Hardware topology capture (SNC off) | Fedora 43 | 1.36.0-rc.0 | All 4 | 2 NUMA, 5 DeviceClasses (4 tight + 1 full) | 2026-04-17 |
| E2E pod scheduling (SNC off) | Fedora 43 | 1.36.0-rc.0 | All 4 | 2 eighth pods running, full 4-driver NUMA alignment | 2026-04-17 |
| KubeVirt single-NUMA VFIO (VEP 115+DRA) | Fedora 43 | 1.36.0-rc.0 | GPU, NIC | VM running, GPU+NIC on guest NUMA 0 via pxb-pcie | 2026-04-17 |
| KubeVirt dual-NUMA VFIO (VEP 115+DRA) | Fedora 43 | 1.36.0-rc.0 | GPU, NIC | VM with 2 guest NUMA nodes, device-only cell for NUMA 1 | 2026-04-17 |

## Feature Matrix

| Feature | OCP 4.21 (K8s 1.34) | Fedora 43 (K8s 1.36) |
|---------|---------------------|---------------------|
| GPU + NIC NUMA alignment | Yes (3 drivers) | Yes (4 drivers) |
| CPU DRA exclusive pinning | Yes (basic) | Yes (DRAConsumableCapacity) |
| Memory DRA NUMA pinning | No | Yes |
| Hugepages via DRA | No | Yes |
| KEP-5304 metadata | Yes (driver-side) | Yes (native API) |
| DRAConsumableCapacity | No (not available) | Yes (beta) |
| Topology coordinator partitions | Yes (quarter only) | Yes (eighth, quarter, full) |
| KubeVirt GPU VFIO via DRA | Partial (device plugin) | Yes (DRA + KEP-5304) |
| KubeVirt guest NUMA (VEP 115) | Yes (CPU-based only) | Yes (device-aware, patched) |
| Multi-driver metadata | Not tested | Broken (kubelet injects one driver per claim) |

## Patches Required per Platform

| Component | OCP 4.21 Patches | K8s 1.36 Patches | Notes |
|-----------|-----------------|-----------------|-------|
| AMD GPU DRA Driver | 7 | 9 | +VFIO support, +K8s 1.36 API renames |
| SR-IOV NIC DRA Driver | 3 | 5 | +VFIO skip RDMA/CNI |
| DRA CPU Driver | 0 | 0 | Works unpatched |
| DRA Memory Driver | N/A | 2 | Not tested on OCP |
| Topology Coordinator | 4 | 6 | +proportional partitions, +capacity |
| KubeVirt | 2 | 7 | +VEP 115 DRA fix, +VFIO caps |
| containerd | N/A | 1 | Built from main for NRI v0.11.0 |

## Workload Configurations Tested

| Configuration | Pods | Per-Pod Resources | NUMA | Status |
|--------------|------|-------------------|------|--------|
| Quarter-machine (manual CEL) | 4 | 32 CPUs + 2 GPUs + 2 NICs + 128 GiB | Pinned | Working |
| Half-machine (manual CEL) | 2 | 64 CPUs + 4 GPUs + 4 NICs | Pinned | Working |
| Eighth-machine (coordinator) | 8 | 8 CPUs + 1 GPU + 2 NICs + memory | Auto | Working |
| Quarter-machine (coordinator) | 4 | 16 CPUs + 1 GPU + 2 NICs + 8 GiB | Auto | Working |
| Full-machine (coordinator) | 1 | All devices | N/A | Working |
| KubeVirt VM single-NUMA (DRA VFIO) | 1 | 4 vCPUs + 1 GPU + 1 NIC + 4 GiB hugepages | 1 guest NUMA | Working (patched) |
| KubeVirt VM dual-NUMA (DRA VFIO) | 1 | 4 vCPUs + 2 GPUs + 2 NICs + 4 GiB hugepages | 2 guest NUMA | Working (patched) |
| Mixed pod + VM | 2 | Pod: CPUs+NICs, VM: GPUs+NICs | Both | Working |

## SNC-2 On vs Off Comparison

Same hardware (Dell XE9680), same software, different BIOS setting:

| | SNC-2 ON | SNC OFF |
|--|----------|---------|
| NUMA nodes | 4 | 2 |
| CPUs per node | 32 | 64 |
| RAM per node | ~500 GB | ~1 TB |
| Partition DeviceClasses | 9 | 5 |
| Tight coupling (GPU+NIC same pcieRoot) | 4 (NUMA 0, 2) | 4 (NUMA 0, 1) |
| Loose coupling (GPU-only, no NIC on switch) | 4 (NUMA 1, 3) | 0 |
| Result | Distance-based fallback needed | All partitions tight |

Key finding: the coordinator adapts automatically to SNC changes without configuration.

## Bugs Found and Fixed (2026-04-17)

| Bug | Root Cause | Fix | Repo |
|-----|-----------|-----|------|
| pcieRoot matchAttribute unsatisfiable | CPU/memory drivers included in pcieRoot constraint | Filter constraint requests to only drivers publishing the attribute | topology-coordinator |
| GPU pods ContainerCreating error | GPU driver applying ROCm config to VFIO VFs | Deploy patched GPU driver with VFIO support | k8s-gpu-dra-driver |
| virt-controller rejects DRA hostDevices | Unpatched virt-controller checking permittedHostDevices | Deploy patched virt-controller, disable operator reconciliation | kubevirt |
| KEP-5304 metadata path mismatch | Template claims under `resourceclaimtemplates/` not `resourceclaims/` | Search both directories in resolveClaimMetadata | kubevirt |
| libnbd ABI mismatch | virt-launcher built on Fedora 43, base image is RHEL 9 | Build with CentOS Stream 9 container | kubevirt |
| Multi-device DRA requests | KubeVirt expects 1 device per request, coordinator uses count>1 | Use count:1 per claim (needs upstream fix for multi-device) | kubevirt |

## Cross-System Hardware Comparison

Four systems tested, three architectures, covering Intel Sapphire Rapids and AMD Turin Classic/Dense:

| | Dell XE9680 | Supermicro AS-8126GS-TNMR | Dell R7725 |
|--|-------------|---------------------------|------------|
| **CPU** | 2x Xeon Gold 6448Y (SPR) | 2x EPYC 9575F (Turin) | 2x EPYC 9825 (Turin Dense) |
| **Cores** | 64c / 128t | 128c / 256t | 288c / 576t |
| **GPUs** | 8x MI300X | 8x MI325X | None (4 empty slots) |
| **NICs** | 2x CX-6 Dx | 7x POLLARA-1Q400 + 1x CX-7 IB | BCM57504 + CX-6 Dx + BCM57508 |
| **NVMe** | None (GPU-local) | 6x KIOXIA CD8P | 4x Samsung PM1745 |
| **PCI domains** | Single (`0000:`) | Single (`0000:`) | Dual (`0000:` + `0001:`) |
| **IOMMU type** | Intel VT-d (DMAR) | AMD IVHD (8 instances) | AMD IVHD (8 instances) |
| **SNC/NPS modes tested** | SNC-2, SNC-off | NPS1 | NPS1, NPS4, L3-as-NUMA |

### GPU + NIC Co-Placement Coverage

| System | `pcieRoot` GPU↔NIC | `numaNode` GPU↔NIC | Notes |
|--------|-------------------|-------------------|-------|
| XE9680 (SNC-2) | 2/8 (25%) | 4/8 (50%) | Only 2 PCIe roots have both GPU + NIC |
| XE9680 (SNC-off) | 2/8 (25%) | 8/8 (100%) | numaNode is coarse (4 GPU/node) |
| SMC6216GPU (NPS1) | 8/8 (100%) | 8/8 (100%) | Every GPU has co-located NIC on same switch |
| SMC6216GPU (NPS4*) | 8/8 (100%) | 8/8 (100%) | numaNode matches pcieRoot under NPS4 |
| R7725 (NPS4) | N/A | N/A | GPU slots and NICs on different quadrants |

*NPS4 not tested on SMC6216GPU, predicted from IOD quadrant mapping.

### Key Conclusions

1. **`pcieRoot` is the only universally reliable co-placement constraint.** It accurately reflects what the hardware provides regardless of BIOS settings. `numaNode` depends on NPS/SNC mode — a setting the DRA driver doesn't control.

2. **Board layout matters more than CPU architecture.** SMC6216GPU and R7725 both use AMD Turin with identical IOD structures, but the SMC co-locates GPU+NIC+NVMe per switch while the R7725 separates them across quadrants.

3. **NPS/SNC changes `numaNode` granularity but not `pcieRoot`.** On the SMC6216GPU, NPS4 makes `numaNode` converge to `pcieRoot`. On the XE9680, they never match because the GPU-to-root mapping isn't 1:1.

4. **IOD quadrant = IOMMU instance = natural scheduling domain on AMD.** Each `ivhd` owns 2 PCIe roots and at most 1 GPU. Under NPS4, each quadrant = 1 NUMA node.

5. **L3-as-NUMA is a CPU cache optimization, not an I/O optimization.** All same-socket CCDs are equidistant (distance 11) to PCIe roots. No I/O locality benefit beyond socket level.

6. **NVMe co-location is hardware-dependent and often incomplete.** SMC: 6/8 roots have NVMe. XE9680: none. R7725: all NVMe on one socket, no GPUs. Should be a soft preference, not a hard constraint.

7. **Intel and AMD need different IOMMU domain detection.** AMD uses `ivhd*`, Intel uses `dmar*`. The hw-topology.sh script currently supports AMD IOD mapping only.

## Detailed Results

- [OCP 4.21 Baseline Results](ocp421-xe9680.md)
- [K8s 1.36 Full Stack Results](k8s136-fedora43.md)
- [KubeVirt Integration](../../docs/kubevirt-integration.md)
- [Topology Coordinator Partitioning](../../docs/topology-coordinator.md)

### Hardware Captures
- [XE9680 SNC-2 ON (4 NUMA)](xe9680-hardware/) — Intel SPR, PCIe tree, IOMMU groups, lstopo, ResourceSlices, DeviceClasses
- [XE9680 SNC OFF (2 NUMA)](xe9680-hardware-snc-off/) — same captures, plus e2e test results
- [SMC6216GPU (NPS1)](smc6216gpu-hardware/) — AMD Turin, 8x MI325X, IOD quadrant mapping, Excalidraw diagrams
- [R7725 (NPS1/NPS4/L3-as-NUMA)](r7725-hardware/) — AMD Turin Dense, compute-only, 3 NPS mode captures with diagrams

### E2E Test Results (2026-04-17)
- [Pod scheduling test](xe9680-hardware-snc-off/e2e-test-running.txt) — 2 eighth pods with 4-driver NUMA alignment
- [KubeVirt single-NUMA test](xe9680-hardware-snc-off/kubevirt-vfio-numa-test.txt) — VM with 1 GPU + 1 NIC on guest NUMA 0
- [KubeVirt dual-NUMA test](xe9680-hardware-snc-off/kubevirt-dual-numa-test.txt) — VM with devices from both NUMA nodes, 2 pxb-pcie expanders, device-only guest NUMA cell

### Upstream Proposals
- [Standardize numaNode with pcieRoot fallback](../../docs/upstream-proposals/standardize-numanode-with-pcieroot-fallback.md)
- [KEP-5304 auto-populate metadata](../../docs/upstream-proposals/kep5304-auto-populate-metadata.md)
- [KubeVirt multi-device DRA requests](../../docs/upstream-proposals/kubevirt-multi-device-dra-requests.md)
- [SNC/NPS topology gap](../../docs/upstream-proposals/numa-snc-nps-topology-gap.md)

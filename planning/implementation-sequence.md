# Implementation Sequence

Phases are independently useful — each unblocks a specific capability. Phases 1-3 are pod-focused. Phase 4 bridges to VMs. Phase 5 is KubeVirt-specific. Phase 6 is community engagement.

## Phase 1: Standardize Attributes

Unblocks native cross-driver NUMA alignment without middleware.

| # | Item | What | Where | Status |
|---|------|------|-------|--------|
| 1 | `numaNode` standardization | Add `resource.kubernetes.io/numaNode` to `deviceattribute` package, all drivers publish it | `k8s.io/dynamic-resource-allocation` + all PCI DRA drivers | Not started |
| 2 | `cpuSocketID` standardization | Add `resource.kubernetes.io/cpuSocketID` to same package, resolves SNC/NPS objection | Same | Not started |
| 3 | `enforcement: preferred` | Add `enforcement` field to `matchAttribute` — enables fallback hierarchy | K8s scheduler | Not started |

Note: items 1-2 are valuable without item 3. A single required `numaNode` constraint works on hardware where every NUMA has the devices it needs. Item 3 adds the fallback chain for SNC/NPS.

## Phase 2: Driver Patches

Unblocks real-world deployment on current hardware.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 4 | AMD GPU bug fixes | Multi-driver claim filter + version fallback | `johnahull/k8s-gpu-dra-driver` `fix/multi-driver-claim-filter` | Patched, not upstream |
| 5 | KEP-5304 for AMD GPU | pciBusID + numaNode in PrepareResult metadata | `johnahull/k8s-gpu-dra-driver` `feat/kep5304-device-metadata` | Patched, not upstream |
| 6 | KEP-5304 for SR-IOV NIC | pciBusID in PrepareResult metadata | `johnahull/dra-driver-sriov` `feature/dra-topology-co-placement` | Patched, not upstream |
| 7 | KEP-5304 auto-populate | Kubelet reads numaNode from sysfs for any device with pciBusID — no driver changes | Proposal only | Not started |

## Phase 3: Topology Coordinator

Unblocks partition abstraction (machine slices) and distance-based fallback.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 9 | Per-driver CEL selectors | Replace cross-driver matchAttribute with per-driver CEL | `johnahull/k8s-dra-topology-coordinator` `fix/per-driver-cel-selectors` | Patched, not upstream |
| 10 | Distance-based fallback | pcieRoot → numaNode with tight/local coupling labels | `fix/distance-based-fallback` | Patched, not upstream |
| 11 | pcieRoot constraint filtering | Exclude CPU/memory from pcieRoot matchAttribute | `fix/pcieroot-constraint-non-pci-drivers` | Patched, not upstream |
| 12 | Webhook CEL forwarding | Forward user CEL selectors through webhook expansion | `fix/webhook-forward-cel-selectors` | Patched, not upstream |

## Phase 4: KubeVirt DRA Bridge

Unblocks correct guest NUMA topology for DRA-allocated devices.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 13 | DRA NUMA guest topology | KEP-5304 metadata → VEP 115 pxb-pcie placement, device-only NUMA cells | `johnahull/kubevirt` `feature/dra-numa-guest-topology` | Patched, not upstream |
| 14 | Multi-device DRA requests | KubeVirt support for count>1 in DRA host device requests | Proposal at `docs/upstream-proposals/kubevirt-multi-device-dra-requests.md` | Not started |

## Phase 5: VFIO Passthrough

Unblocks GPU and NIC passthrough to KubeVirt VMs via DRA.

| # | Item | What | Branch | Status |
|---|------|------|--------|--------|
| 15 | AMD GPU VFIO support | Discovery + config + CDI + bind/unbind for vfio-pci devices | `johnahull/k8s-gpu-dra-driver` `feature/vfio-passthrough` | Patched, not upstream |
| 16 | GIM kernel compat | `vm_flags_set()` for kernel 6.3+ | `johnahull/MxGPU-Virtualization` `fix/kernel-6.17-compat` | Patched, not upstream |
| 17 | KubeVirt VFIO support | Locked memory, capabilities, root mode, seccomp, permittedHostDevices skip | `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough` | Patched, not upstream |
| 18 | SR-IOV NIC VFIO patches | NAD-optional, RDMA-skip, NRI CNI-skip for vfio-pci bound VFs | Lost from XE9680, needs reimplementation | Not started |

## Phase 6: Upstream Proposals

Community engagement and formal proposals.

| # | Item | What | Doc | Status |
|---|------|------|-----|--------|
| 19 | KEP-5304 auto-populate issue | File upstream issue for kubelet auto-populating numaNode from sysfs | `docs/upstream-proposals/kep5304-auto-populate-metadata.md` | Not filed |
| 20 | KubeVirt multi-device issue | File upstream issue for count>1 DRA host device requests | `docs/upstream-proposals/kubevirt-multi-device-dra-requests.md` | Not filed |
| 21 | numaNode + cpuSocketID proposal | Socialize distance hierarchy with SIG-Node / device management WG | `docs/upstream-proposals/proposal-topology-distance-hierarchy.md` | Ready to post |

## Dependencies

```
Phase 1 (attributes) ← standalone, unblocks native alignment
Phase 2 (drivers) ← standalone, unblocks deployment
Phase 3 (coordinator) ← standalone, works without Phase 1
Phase 4 (KubeVirt bridge) ← benefits from Phase 2 (KEP-5304 metadata)
Phase 5 (VFIO) ← requires Phase 2 (driver patches) + Phase 4 (guest NUMA)
Phase 6 (proposals) ← informed by all phases, can start anytime
```

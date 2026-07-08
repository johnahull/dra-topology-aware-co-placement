# DRA Topology Coordinator — Feature Demo

Demonstrates the topology coordinator's core features on an AMD MI355X server with 8 NUMA nodes, 8 PCIe root complexes, GPU VFs, and SR-IOV NIC VFs.

## What's shown

1. **Hardware topology** — Socket/NUMA/PCIeRoot device tree via `dra-verify.sh topology`
2. **ResourceSlice summary** — device counts per driver via `dra-verify.sh slices`
3. **Topology attributes** — per-driver attribute table via `dra-verify.sh attributes`
4. **Active DRA drivers** — GPU, NIC, CPU, memory via `dra-verify.sh drivers`
5. **Partition DeviceClasses** — pcieroot, numa, full with sub-resources and alignment
6. **Tier-named aggregates** — eighth, quarter, half mapped from PCIe root fractions
7. **Auto-detected GPU+NIC pairings** — 8 rails with deterministic railIndex
8. **SLIT-aware reachability** — numa aggregate config including reachable NICs
9. **Webhook claim expansion** — `eighth` → per-driver sub-requests + alignment constraints
10. **Multi-partition claims** — `count=3` creates 3 independent partition groups
11. **Pod deployment** — pods requesting eighth, numa, and 2x eighth partitions
12. **Claim allocation** — `dra-verify.sh claims` showing topology-aligned device placement
13. **DeviceClass availability** — slots marked in-use after pod scheduling

## Recording

```bash
# Run the demo (pre-start pods if needed)
vhs demo.tape
```

Outputs: `demo.gif`, `demo.mp4`

## Files

| File | Description |
|------|-------------|
| `demo.tape` | VHS recording script |
| `demo-claim-eighth.yaml` | ResourceClaim for 1x eighth partition |
| `demo-claim-3eighths.yaml` | ResourceClaim for 3x eighth partitions |
| `demo-pod-eighth.yaml` | Pod + ResourceClaimTemplate for 1 eighth |
| `demo-pod-quarter.yaml` | Pod + ResourceClaimTemplate for 1 numa (quarter) |
| `demo-pod-2eighth.yaml` | Pod + ResourceClaimTemplate for 2 eighths |
| `show-claim.sh` | Helper: display expanded claim sub-requests and constraints |
| `show-config.sh` | Helper: display PartitionConfig from a DeviceClass |
| `show-labels.sh` | Helper: display labels on a DeviceClass |

## Prerequisites

- Kubernetes 1.37+ with DRA enabled
- Topology coordinator deployed with webhook
- DRA drivers: GPU, CPU, memory, NIC (dranet or SR-IOV)
- `dra-verify.sh` in PATH (from `testing/scripts/`)

# Recordings

Terminal recordings of DRA topology-aware co-placement demos, generated with [VHS](https://github.com/charmbracelet/vhs).

## XE8640 DRA Verification

Demonstrates the DRA topology verification tools and a half+quarters co-placement demo on the Dell XE8640 (4x H100 SXM5).

![XE8640 DRA Verification](xe8640-dra-verify.gif)

**Commands shown:**

1. `numa-topology.sh -p -f -a` — NUMA topology with PCIe accelerators
2. `dra-verify.sh topology -v` — DRA device topology (verbose)
3. `dra-verify.sh slices` — ResourceSlice summary
4. `dra-verify.sh deviceclasses` — Topology coordinator device classes
5. `dra-verify.sh claims` — Allocated claims (empty before demo)
6. Apply `demo-half-and-quarters.yaml` — Mixed half + 2 quarters partition demo
7. `kubectl get pods` / `kubectl get resourceclaims` — Verify resources created
8. `dra-verify.sh claims` — Allocated claims (after demo)
9. `dra-verify.sh deviceclasses` — Device classes showing allocation status

**Re-record:**

```bash
vhs testing/recordings/xe8640-dra-verify.tape
```

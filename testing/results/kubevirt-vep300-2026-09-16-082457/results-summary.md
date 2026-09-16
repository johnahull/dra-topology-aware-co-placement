# VEP-300 live test results

Date: 2026-09-16
Server: `jhull@10.6.62.52`
KubeVirt branch: `feature/vep-300-managed-dra-claims`

This report covers VEP-300 managed DRA claims only. Generic VFIO/KubeVirt
launcher fixes and DRA-driver preparation are documented separately in
[`vfio-kubevirt-fix-scope.md`](vfio-kubevirt-fix-scope.md).

## Results

| Test | Result | Evidence |
|---|---|---|
| VEP-300 feature gates and controller | PASS | Managed DRA gates were enabled and the managed-claim controller was Ready. |
| Managed GPU+NIC claim generation | PASS | The controller created deterministic generated ResourceClaims for the VMI managed-claim entry. |
| Generated claim contents | PASS | The claim contained one GPU request, one NIC request, and the provisioner-generated device configuration. |
| GPU+NIC PCI-root co-placement | PASS | The scheduler allocated GPU and NIC devices from the same `resource.kubernetes.io/pcieRoot`. |
| Two persistent GPU+NIC VMs | PASS | `amd-managed-gpu-nic-a` and `amd-managed-gpu-nic-b` reached `Running` with `Ready=True`. |
| Guest end-to-end confirmation | PASS | Both guests exposed one AMD GPU VF and one ConnectX VF, confirming the managed claims reached the launcher. |
| Missing generated claim diagnostic | PASS | A disposable VMI reported `ManagedClaimsReady=False` with generated claim and provisioner context while the managed-claim controller was paused. |
| Unallocated generated claim diagnostic | PARTIAL | The generated claim existed but could not allocate an additional aligned pair; the VMI remained `ManagedClaimsReady=False`, but the allocation-specific condition message was not confirmed before cleanup. |
| Managed controller recovery | PASS | The managed-claim controller was restored and returned to two Ready replicas; the disposable VM and claim were then cleaned up. |
| VM restart and claim reacquisition | PASS | Restarting `amd-managed-gpu-nic-a` reacquired its claim while `amd-managed-gpu-nic-b` remained Running. |
| VM cleanup and recreation | PASS | Stopping a VM removed its VMI and managed claim; `runStrategy: Always` recreated them successfully. |
| GPU DRA driver restart resilience | PASS | Existing managed claims and VMIs remained healthy after the GPU driver DaemonSet restart. |
| SR-IOV DRA driver restart resilience | PASS | Existing managed claims and VMIs remained healthy after the SR-IOV driver DaemonSet restart. |

## Diagnostic evidence

The deployed diagnostics controller reported the following VMI condition for
the disposable test VM while its generated claim was absent:

```text
ManagedClaimsReady=False
Reason=NotAllManagedClaimsReady
Message=Managed ResourceClaims not yet created: vep300-diagnostics-test-gpu-nic-a (provisioner vep300-gpu-nic-aligner)
```

After the managed-claim controller resumed, the generated claim was created,
but the node had no additional aligned GPU/NIC pair available. The VMI
remained pending and Kubernetes emitted a scheduler event that the node could
not allocate all claims. The allocation-specific VEP-300 status message could
not be confirmed before cleanup. The disposable VM was deleted without
affecting the two persistent test VMs.

## Evidence archive

- `test-plan.md`
- `manifests/managedclaimprovisioner-gpu-nic.yaml`
- `manifests/managed-vmi-gpu-nic.yaml`
- `tests/managed-gpu-nic-*.log`
- `logs/managed-claim-controller-debug.log`
- `snapshots/managed-gpu-nic-rerun.yaml`
- `metadata/cluster-baseline.txt`

## Limitations

- The cluster is single-node; migration is not tested.
- No additional aligned GPU/NIC pair was available for a successful
  allocation-recovery assertion after the diagnostics test.
- The missing-claim diagnostic was verified; the distinct unallocated-claim
  diagnostic needs a follow-up run with a deliberately unavailable claim and
  an available aligned pair for the remaining resources.
- Unsatisfiable DRA scheduler diagnostics remain owned by Kubernetes/DRA and
  are not counted as VEP-300 provisioning diagnostics.
- Pre-existing failed AMD operator pods are environmental noise.

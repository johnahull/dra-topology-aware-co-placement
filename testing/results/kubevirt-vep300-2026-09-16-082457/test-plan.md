# KubeVirt VEP-300 managed DRA claim validation

This plan validates the VEP-300 managed-claim implementation: converting VMI
device declarations into generated `ResourceClaim` objects, allowing DRA to
allocate those claims with topology constraints, and maintaining correct
claim/VMI lifecycle behavior.

Generic VFIO device preparation, SR-IOV driver behavior, CDI generation, and
KubeVirt PCI-aperture changes are tracked separately in
[`vfio-kubevirt-fix-scope.md`](vfio-kubevirt-fix-scope.md).

## Acceptance criteria

- A VMI managed claim produces a deterministic generated `ResourceClaim`.
- The generated claim contains the expected GPU and NIC requests and
  provisioner-generated configuration.
- A GPU+NIC managed claim allocates devices satisfying the intended
  `resource.kubernetes.io/pcieRoot` constraint.
- The VMI exposes `ManagedClaimsReady=False` while generated claims are
  missing or unallocated, with useful claim/provisioner context.
- The VMI exposes `ManagedClaimsReady=True` after all generated claims are
  allocated.
- VM/VMI stop, restart, deletion, and claim recreation do not leak managed
  claims or affect an unrelated running VM.
- Provisioner and ResourceClaim informer updates cause reconciliation.
- Existing direct and template ResourceClaims remain unaffected.

## Test matrix

| Area | Test | Expected result |
|---|---|---|
| Generation | One managed GPU claim | Deterministic generated ResourceClaim is created. |
| Generation | GPU+NIC managed claim | One claim contains both device requests and generated configuration. |
| Topology | GPU+NIC `pcieRoot` alignment | Scheduler allocates both devices from the requested PCIe root. |
| Status | Generated claim missing | `ManagedClaimsReady=False` identifies the generated claim and provisioner. |
| Status | Generated claim unallocated | `ManagedClaimsReady=False` identifies the unallocated claim. |
| Status | All claims allocated | `ManagedClaimsReady=True` with `AllManagedClaimsReady`. |
| Diagnostics | Generation error | Warning Event includes claim, generated ResourceClaim, provisioner, and error. |
| Lifecycle | VM restart | Claim is released/reacquired without affecting another VM. |
| Lifecycle | VM deletion/recreation | Generated claim and finalizer lifecycle converges without leaks. |
| Resilience | GPU/SR-IOV driver restart | Existing managed claims and VMIs remain represented correctly after driver recovery. |
| Isolation | Direct/template claims | They are not reconciled as managed claims. |

## Executed scope

The live run covered one and two persistent GPU+NIC VMs, PCI-root
co-placement, managed-claim recreation, independent VM restart, driver
restart resilience, and guest-level device visibility as an end-to-end
confirmation that the allocated managed claims reached the launcher.

The diagnostics implementation was subsequently deployed and exercised with a
disposable VM while the managed-claim controller was paused. The VMI reported
the missing generated claim and provisioner in `ManagedClaimsReady=False`.
After the controller resumed, the generated claim was created but could not be
allocated because no additional aligned GPU/NIC pair was available. The
allocation-specific status message was not confirmed in that constrained run.
The controller was restored and the disposable VM was removed.

## Out of scope

- How the AMD GPU or SR-IOV DRA driver binds devices to `vfio-pci`.
- CDI file construction and device-node permissions.
- NRI registration, NAD lookup, or RDMA setup.
- KubeVirt virt-launcher PCI-hole sizing and locked-memory implementation.
- IOMMUFD versus legacy VFIO backend selection.
- Guest PCI-root placement beyond confirming that the managed claim reached
  the launcher.

Those items are recorded separately in `vfio-kubevirt-fix-scope.md`.

## Environment limitations

- The cluster is single-node; migration is not tested.
- The available aligned GPU/NIC pairs were consumed by the persistent VMs,
  so the disposable diagnostics VM could demonstrate claim creation and
  unallocated status but not successful allocation recovery.
- Pre-existing failed AMD operator pods are environmental noise.

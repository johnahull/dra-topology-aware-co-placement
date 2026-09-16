# VEP-300 Scope Boundary: Managed DRA Diagnostics

**Document status:** Draft
**Scope:** KubeVirt VEP-300 managed claims
**Last updated:** 2026-09-16

## Purpose

This document defines which diagnostics belong in KubeVirt VEP-300 and which belong in Kubernetes DRA or an individual DRA driver. The boundary prevents VEP-300 from duplicating scheduler-owned allocation status or device-driver behavior.

## Responsibility boundary

| Failure or behavior | Owner | VEP-300 responsibility |
|---|---|---|
| Invalid or missing `ManagedClaimProvisioner` reference | KubeVirt VEP-300 | Reject or report the VMI configuration clearly. |
| Managed device declaration cannot be translated into a `ResourceClaim` | KubeVirt VEP-300 | Emit an Event and set the VMI’s `ManagedClaimsReady` condition to `False` with a stable reason and message. |
| Provisioner mapping is incomplete or malformed | KubeVirt VEP-300 | Report the affected VMI, claim name, device type, and mapping error. |
| Generated `ResourceClaim` is not allocated | Kubernetes DRA scheduler/allocator | Report device-class, selector, capacity, and topology allocation failures. |
| Device does not match a DRA selector | Kubernetes DRA scheduler/allocator | Explain why no device matched. |
| No device satisfies a `matchAttribute` constraint | Kubernetes DRA scheduler/allocator | Explain the unsatisfied attribute or topology constraint. |
| VFIO binding, CDI generation, or device preparation failure | DRA driver | Report the prepare/unprepare failure and restore state where possible. |
| GPU/NIC driver or hardware failure | AMD or SR-IOV DRA driver | Report driver-specific diagnostics and recovery status. |
| Guest PCI placement or root-complex layout | KubeVirt PCI placement implementation | Handle guest topology placement separately from VEP-300 claim generation. |

## Recommended VEP-300 behavior

VEP-300 should improve diagnostics only for failures it owns:

1. Emit a Kubernetes Event on the affected VMI when managed-claim generation fails.
2. Set `ManagedClaimsReady=False` with a stable reason such as `ManagedClaimGenerationFailed`.
3. Include actionable context in the condition message:
   - managed claim name;
   - device type and request name;
   - provisioner name; and
   - the validation or generation error.
4. Clear the failure condition after a later reconciliation succeeds.

VEP-300 should not write allocation results into `ResourceClaim.status`; that status is owned by Kubernetes DRA. It should also not put per-VMI failures into `ManagedClaimProvisioner.status`, because the provisioner object is shared by many VMIs.

## Important distinction

An unreferenced `ResourceClaim` that remains unallocated may have no useful status or Events because no Pod or VMI has caused a scheduling decision. That is not, by itself, a VEP-300 failure. Allocation diagnostics should be tested with a consuming Pod or VMI and evaluated through scheduler Events and DRA allocation status.

## Non-goals

- Adding a second allocation-status API to VEP-300.
- Changing Kubernetes DRA scheduler behavior.
- Replacing DRA driver diagnostics.
- Encoding guest PCI-root placement in managed-claim provisioning.
- Modifying `ResourceClaim.status` or `ManagedClaimProvisioner.status` for request-specific errors.

## Acceptance criteria

- A managed-claim generation failure produces a VMI Event.
- The VMI reports `ManagedClaimsReady=False` with a stable reason.
- The condition identifies the affected managed claim and provisioner.
- Successful reconciliation clears the failure condition.
- DRA allocation failures remain visible through Kubernetes scheduler/DRA status rather than being duplicated by VEP-300.

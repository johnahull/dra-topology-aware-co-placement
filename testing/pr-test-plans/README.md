# AMD GPU DRA driver PR test plans

These plans cover the AMD GPU DRA driver pull requests under review:

- [PR #91 — KEP-4815 dual-entry advertising](pr-91-kep4815-dual-entry.md)
- [PR #114 — IOMMUFD support](pr-114-iommufd.md)
- [PR #122 — VFIO conversion lifecycle](pr-122-vfio-conversion-lifecycle.md)

Executable live-system runbooks:

- [PR #91 live runbook](live-runbooks/pr-91-kep4815-live.md)
- [PR #114 live runbook](live-runbooks/pr-114-iommufd-live.md)
- [PR #122 live runbook](live-runbooks/pr-122-vfio-lifecycle-live.md)

Status is recorded as of 2026-09-24. Hardware validation is intentionally
hardware-agnostic: the target is an available AMD SR-IOV/GIM-capable test
system, not a specific server model. Results from an earlier XE9680 session
are prior evidence only and are not the required validation target for these
plans.

The plans distinguish between automated tests, live driver tests, and
KubeVirt integration tests. A test marked as reported complete comes from the
current PR validation notes; it should be rerun after any rebase or additional
commits before final approval.

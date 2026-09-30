# AMD GPU DRA driver PR test plans

These plans cover the AMD GPU DRA driver pull requests under review:

- [PR #91 — KEP-4815 dual-entry advertising](pr-91-kep4815-dual-entry.md)
- [PR #114 — IOMMUFD support](pr-114-iommufd.md)
- [PR #122 — VFIO conversion lifecycle](pr-122-vfio-conversion-lifecycle.md)

Executable live-system runbooks:

- [PR #91 live runbook](live-runbooks/pr-91-kep4815-live.md)
- [PR #114 live runbook](live-runbooks/pr-114-iommufd-live.md)
- [PR #122 live runbook](live-runbooks/pr-122-vfio-lifecycle-live.md)

Status is recorded as of 2026-09-30. The current live target is the
disposable XE9785L MI355X system (`10.14.202.26`); hardware validation remains
hardware-agnostic and the host-specific results below are evidence for this
run only. Results from the earlier XE9680 session remain prior evidence.

The live runs used the [DRA test harness](https://github.com/johnahull/k8s-dra-harness)
for ResourceSlice/resource-publication, allocation, release, capacity, restart,
and topology checks. The harness test-plan configuration now also carries the
opaque `VfioDeviceConfig` needed by the PR #114 backend-policy cases.

The plans distinguish between automated tests, live driver tests, and
KubeVirt integration tests. A test marked as reported complete comes from the
current PR validation notes; it should be rerun after any rebase or additional
commits before final approval.

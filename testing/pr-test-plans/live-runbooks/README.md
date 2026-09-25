# Live-system test runbooks

These runbooks are execution documents for testers or agents validating the
AMD GPU DRA driver PRs on an available AMD system. They are aligned with the
evidence matrices in the parent directory:

- [PR #91 KEP-4815 runbook](pr-91-kep4815-live.md)
- [PR #114 IOMMUFD runbook](pr-114-iommufd-live.md)
- [PR #122 VFIO lifecycle runbook](pr-122-vfio-lifecycle-live.md)

## Common execution rules

Run only on a disposable test node or an isolated GPU/VF. Do not unbind a
production GPU, delete host device nodes, or force a PCI reset on a workload
that matters. If a failure path cannot be injected safely, record it as
automated-only and attach the corresponding unit/component-test evidence.

Set a unique evidence directory before starting:

```bash
export RUN_ID="$(date +%Y%m%d-%H%M%S)"
export RUN_DIR="${PWD}/testing/results/pr-live-${RUN_ID}"
mkdir -p "$RUN_DIR"
```

Record the environment:

```bash
uname -a | tee "$RUN_DIR/uname.txt"
kubectl version -o yaml | tee "$RUN_DIR/kubernetes-version.yaml"
kubectl get nodes -o wide | tee "$RUN_DIR/nodes.txt"
kubectl get deviceclasses -o yaml | tee "$RUN_DIR/deviceclasses-before.yaml"
kubectl get resourceslices -o yaml | tee "$RUN_DIR/resourceslices-before.yaml"
./testing/scripts/hw-topology.sh --simple -p | tee "$RUN_DIR/host-topology.txt"
./testing/scripts/dra-verify.sh drivers | tee "$RUN_DIR/dra-drivers.txt"
./testing/scripts/dra-verify.sh slices | tee "$RUN_DIR/dra-slices.txt"
```

For every scenario, save:

- The exact driver image and source commit.
- The applied claim/workload/VM YAML.
- ResourceClaims before and after allocation.
- ResourceSlices before allocation, during allocation, and after release.
- Driver logs covering discovery, Prepare, Unprepare, and republish.
- CDI YAML and host device-binding state when VFIO is involved.
- A result row with `PASS`, `FAIL`, `BLOCKED`, or `NOT RUN` and an explanation.

Useful verification commands:

```bash
kubectl get resourceclaims -A -o yaml | tee "$RUN_DIR/resourceclaims.yaml"
kubectl get resourceslices -o yaml | tee "$RUN_DIR/resourceslices.yaml"
./testing/scripts/dra-verify.sh attributes -a | tee "$RUN_DIR/attributes.txt"
./testing/scripts/dra-verify.sh claims | tee "$RUN_DIR/claims.txt"
./testing/scripts/dra-verify.sh vfio | tee "$RUN_DIR/vfio.txt"
./testing/scripts/dra-verify.sh counters | tee "$RUN_DIR/counters.txt"
```

The tester must record when a result is not attributable to the PR under test,
for example when a VM passed through a VF but did not exercise the PR's
dual-entry or IOMMUFD behavior.

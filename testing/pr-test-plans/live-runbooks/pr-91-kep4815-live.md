# PR #91 live test runbook: KEP-4815 dual entries

The [PR #91 results matrix](../pr-91-kep4815-dual-entry.md) records case status
and evidence. This runbook is the entry point when the lab node is ready.
Run the mode-specific [harness configurations](https://github.com/johnahull/k8s-dra-harness/tree/feature/pr91-live-hardware-tests/examples/pr91)
against the final PR #91 image. The harness creates and cleans up its own
claims, pods, and VMIs; it does not switch the host between amdgpu and GIM,
deploy the driver image, or modify a checkpoint.

## 1. Prepare one run

Use a dedicated GPU node and a driver image built from the PR head. Do not
install a second copy of `gpu.amd.com` alongside an existing driver. Confirm
Kubernetes serves `resource.k8s.io/v1`, has KEP-4815 partitionable-device
scheduling enabled, and has no unrelated claims on the target GPUs.

```bash
export HARNESS=/home/jhull/devel/k8s-dra-harness
export DRIVER=/home/jhull/devel/amd/k8s-gpu-dra-driver-kep4815-fix
export WORK=/home/jhull/dra-test-work/pr91
export TEST_NODE=<kubernetes-node-name>
export TEST_HOST=<ssh-host-for-that-node>
export DRIVER_NAMESPACE=<installed-driver-namespace>
export RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$DRIVER" rev-parse --short HEAD)"
export EVIDENCE=/home/jhull/dra-test-work/evidence/pr91-$RUN_ID
mkdir -p "$WORK" "$EVIDENCE"
cp "$HARNESS"/examples/pr91/*.yaml "$WORK"/
```

Edit the copied YAML for the driver namespace, target node, inventory path,
`REPLACE-RUN-ID`, and any PCI BDF placeholders. Use the actual `kubectl get
node` name for `targetNode`. The harness reads the node's hostname label to
place pods without bypassing the scheduler. Keep a separate copied config
and evidence directory for each host mode, VF count, and qualified PF: the
harness uses fixed snapshot names and a second run in the same directory
would overwrite the first. For VMI cases, provision the
cloud-init and guest SSH Secrets named in the copied YAML first.

Record the exact image digest, chart values, driver and harness commits, GIM
and kernel versions, and verification-script commit. The examples leave
`expectedRepoCommit` unset; set it to the verification checkout's commit
when that checkout is clean.

```bash
kubectl config current-context | tee "$EVIDENCE/context.txt"
kubectl version -o yaml > "$EVIDENCE/kubernetes-version.yaml"
kubectl api-resources --api-group=resource.k8s.io > "$EVIDENCE/dra-api.txt"
kubectl get nodes -o wide > "$EVIDENCE/nodes.txt"
kubectl get deviceclasses -o yaml > "$EVIDENCE/deviceclasses-before.yaml"
kubectl get resourceslices -o yaml > "$EVIDENCE/resourceslices-before.yaml"
kubectl get resourceclaims -A -o yaml > "$EVIDENCE/resourceclaims-before.yaml"
kubectl get pods -n "$DRIVER_NAMESPACE" -l app.kubernetes.io/component=kubeletplugin -o wide > "$EVIDENCE/plugin-pods.txt"
kubectl get pods -n "$DRIVER_NAMESPACE" -l app.kubernetes.io/component=kubeletplugin -o yaml > "$EVIDENCE/plugin-pods.yaml"
ssh "$TEST_HOST" 'uname -a; lspci -D -nn; cat /proc/cmdline' > "$EVIDENCE/host-before.txt"
git -C "$DRIVER" rev-parse HEAD > "$EVIDENCE/driver-commit.txt"
git -C "$HARNESS" rev-parse HEAD > "$EVIDENCE/harness-commit.txt"
git -C /home/jhull/devel/dra-topology-aware-co-placement rev-parse HEAD > "$EVIDENCE/verification-commit.txt"
```

From the driver checkout, export
`LD_LIBRARY_PATH="$PWD/third_party/amd_smi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"`,
then run `go test ./...`, `go vet ./...`,
`go test -race ./cmd/gpu-kubeletplugin`, and
`python3 scripts/test-deviceclasses.py`. From the harness checkout, run
`make unit-test` and `python3 scripts/test_pr91_host_inventory.py`.

Capture the hardware inventory **after every host mode or VF-count change**:

```bash
ssh "$TEST_HOST" python3 - --node "$TEST_NODE" \
  < "$HARNESS/scripts/pr91-host-inventory.py" \
  > "$WORK/<mode>-inventory.json"
```

The inventory records the PF/VF BDFs, bindings, active VF count, IOMMU group,
PCI device ID, and PF VRAM source used by the live assertions. Review it
before running a claim. Do not edit it to match an unexpected ResourceSlice.

For each copied config, the actual execution command is:

```bash
cd "$HARNESS"
KUBECONFIG=<lab-kubeconfig> \
DRA_HARNESS_CONFIG="$WORK/<mode>.yaml" \
TEST_FEATURES=dra make run-tests
```

## 2. MI300X with amdgpu, no GIM VFs

Deploy the final PR image and matching Helm chart with
`featureGates.VFIOPassthrough=true` and `AutoPartition=false`. Record the pod
`imageID` digest and actual Helm values. Confirm each test PF is on amdgpu,
has `sriov_numvfs=0`, and has a usable IOMMU group. Run
`mi300x-dual.yaml` after capturing `mi300x-dual-inventory.json`.

Expected: each eligible PF has one compute and one BDF-stable VFIO entry
with the same PCI identity and capacity. Both consume one capacity-1
`fn-<BDF>` counter in `pf-<BDF>-counter-set`; no `vf-slots` exists. The
compute workload and an idle plugin restart succeed. The chart provides
`gpu.amd.com` for compute and `gpu.amd.com-vfio` for VFIO. Check these
selectors with the Helm test and the saved DeviceClass snapshot.

**Do not run a VFIO PF consumer on MI300X.** A previous MI300X session found
that a VFIO reset could make PF PCI config space unreadable until a host
reboot. This includes the harness sibling and class-isolation Pod scenarios:
if a counter or class is wrong, the supposedly pending VFIO Pod could Prepare.
Use the scheduler allocator test from draft PR #133 against saved slices for
the MI300X allocation model; reserve live PF allocation tests for a
qualified platform.

With no active VFIO claims, temporarily disable the VFIO gate, restart the
plugin, and save DeviceClasses and ResourceSlices. Expect compute entries
but no VFIO entries or function counters. Restore the gate and confirm the
original publication. This gate-off/on check is an explicit runbook step,
not a harness scenario.

## 3. MI300X AutoPartition plus VFIO gate

On an isolated amdgpu MI300X node, enable both `AutoPartition` and
`VFIOPassthrough`, capture `mi300x-auto-inventory.json`, and run
`mi300x-auto.yaml`. Expect synthetic SPX and partition candidates with
valid `gpu-<index>-mutex` counters and no direct VFIO sibling of a
synthetic partition. The chart must also provide `gpu.amd.com-spx` for
whole-GPU extended-resource requests. This profile does not create a
partition-mode-changing claim. Test real CPX/DPX transitions only with the
node prepared for AMD driver reload and a separate partition runbook.

## 4. MI300X with GIM VFs

Drain claims before changing host mode. Configure GIM with the platform's
supported VF count; do not assume that 2, 4, or 8 VFs per PF are supported.
For a GIM-only node, the current chart's init container waits for amdgpu.
Apply and record the lab's init-container command override after each
deployment or Helm upgrade; otherwise the plugin never starts and VF
discovery is not tested.

Capture a fresh inventory and run a separate copy of `mi300x-gim.yaml` for
one VF per PF, then for one supported multi-VF setting if available. Set a
different `hostInventory` path and `evidenceDir` in each copy. Refresh the
inventory and restart discovery after each VF-count change. Expected: GIM
PFs are absent; each eligible `virtfn*` appears once in
`gpu.amd.com-vfio` with `isVF=true`, no `partitionProfile`, and no shared
counter. Per-VF capacity is PF sysfs VRAM divided by `sriov_numvfs` when
that source exists, with MI300X CU/SIMD values `304/N` and `1216/N`.
The harness allocates and releases distinct VFs until the next request is
pending, then restarts the idle plugin. Run `mi300x-gim-vmi.yaml` separately
to verify the guest sees an AMD PCI device and VM deletion releases its VF.

For the **zero-VF** case, drain claims, set the supported GIM VF count to
zero, restart the plugin, and inspect ResourceSlices and logs directly.
The harness's existing-driver preflight requires a nonempty ResourceSlice,
so it cannot run this intentionally empty case. Restore a supported VF
count and recapture inventory before continuing.

## 5. Checkpoint failure and repair

Use only an isolated node with **no active claims**. Confirm the plugin's
host-mounted `KUBELET_PLUGINS_DIRECTORY_PATH`, back up its
`gpu.amd.com/checkpoint.json` outside that plugin directory, and save the
checksum and original permissions. Corrupt a copy on the node, restart
only that node's plugin pod, and capture logs and slices.

With VFIO enabled, expect startup failure mentioning the unreadable
checkpoint. With VFIO disabled, expect startup with no devices published
for that node. The PR's component tests cover rejection of Prepare and
Unprepare while recovery is unavailable; do not strand a live claim just to
invoke those methods. Restore the exact backup, restore the original
feature gate, restart the plugin, and verify normal publication before
leaving this phase. No harness config is used while the checkpoint is bad
because its normal existing-driver preflight correctly rejects an empty pool.

## 6. MI350P direct PF, if the hardware is available

First record the MI350P PF PCI ID. The current GIM CU/SIMD table has entries
for MI300X, MI325X, and MI355X, but no MI350P entry; an unmapped MI350P
must not be reported as a passing CU/SIMD capacity test.

Arrange console and reboot access. Pick a disposable PF, put it on amdgpu
with no VFs, capture `mi350p-qualify-inventory.json`, and run
`mi350p-qualify.yaml` with that exact `targetBDF`. It holds the direct VFIO
claim for 120 seconds. During the hold, capture the host driver symlink,
VFIO group nodes, CDI spec, claim, and plugin logs. After release, confirm
the PF returned to amdgpu and dual publication and its counter returned.
Stop further PF tests if config space, rebind, or driver health fails.

Qualify a second disposable PF with its own copied config and evidence
directory. Only then set `targetBDF` and
`alternateBDF` in `mi350p-direct.yaml` and run it. It checks class isolation,
sibling exclusion in both allocation orders, an active direct-claim plugin
restart, and two independent claims released in both orders. During an
active direct claim after restart, expect the selected BDF to be VFIO-only
with no function counter; after release, expect amdgpu and VFIO entries
and their shared counter again. Optional pre-bound PF mode has its own
`mi350p-prebound.yaml`, and a PF guest test has
`mi350p-direct-vmi.yaml`; run each only in its matching host mode.

## 7. Evidence and completion

For every phase save before/during/after host binding, ResourceSlices,
DeviceClasses, claims, plugin logs, CDI, and VM/guest output where relevant.
The harness writes JSON snapshots and `dra-counters.py` output to each
configured evidence directory. Record each row of the parent results
matrix as **pass**, **fail**, **blocked**, or **not applicable**, with a path
to the evidence and the final image digest.

After cleanup, verify harness-owned claims and consumers are gone and all
host bindings match the phase's recorded baseline. If MI350P is absent or
cannot safely rebind, mark direct-PF live cases **blocked**; the unit tests
remain evidence for rollback and other fault paths, but do not replace a
successful live direct-PF lifecycle test.

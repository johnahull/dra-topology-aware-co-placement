# Issues Found — 2026-04-28

All issues discovered during DRA topology-aware VM testing on R760xa.

## Kubelet Issues (fixed in `johnahull/kubernetes` `feature/enforcement-preferred`)

### 1. DRA topology hints: Node Authorizer denies ResourceSlice list

**Symptom:** `getDRATopologyHints` returns no hints. No error logs at default verbosity.

**Root cause:** The kubelet's Node Authorizer requires a `spec.nodeName` field selector when listing ResourceSlices. Without it, the list request returns `DecisionNoOpinion` and falls through to RBAC denial. The error was logged at V(4), invisible at default verbosity.

**Fix:** Added `FieldSelector: "spec.nodeName=" + m.nodeName` to `ResourceSlices().List()` in `topology_hints.go`. Added `nodeName` field to `Manager` struct, passed from `container_manager_linux.go`.

**Files:** `pkg/kubelet/cm/dra/topology_hints.go`, `pkg/kubelet/cm/dra/manager.go`, `pkg/kubelet/cm/container_manager_linux.go`

---

### 2. CPU manager: reconciler never corrects cgroup cpuset mismatches

**Symptom:** The `cpu_manager_state` file shows CPUs 4,6,68,70 for the compute container, but the cgroup `cpuset.cpus` shows all odd CPUs (NUMA 1). The mismatch persists indefinitely.

**Root cause:** `AddContainer()` set `lastUpdateState` to the desired cpuset without ever calling `updateContainerCPUSet`. The reconciler then compared desired vs "last update" and saw no difference, so it never wrote the cgroup. Any external modification to the cpuset (by containerd, cgroup init, or KubeVirt virt-handler) was invisible to the reconciler.

**Fix:** Removed `lastUpdateState` pre-population from `AddContainer()`. The reconciler now detects the mismatch on its first pass.

**File:** `pkg/kubelet/cm/cpumanager/cpu_manager.go`

---

### 3. CPU manager: cpuset not applied before container starts

**Symptom:** KubeVirt VM fails with `set_mempolicy: Invalid argument` because virt-launcher reads the wrong cpuset at startup. The cpuset is corrected by the reconciler 10+ seconds later, but QEMU has already generated the wrong NUMA mapping and crashed.

**Root cause:** `PreCreateContainer` sets `CpusetCpus` in the CRI config, but containerd doesn't reliably apply it during container creation. The container starts with a cpuset inherited from the pod cgroup (all non-reserved CPUs), not the dedicated assignment. The reconciler corrects it asynchronously, but too late for virt-launcher which reads `cpuset.cpus.effective` immediately at startup.

**Fix:** Added `updateContainerCPUSet()` call in `AddContainer()` (which runs during `PreStartContainer`, before the container process starts). Only triggers for small dedicated cpusets (< 128 CPUs), not the default set.

**File:** `pkg/kubelet/cm/cpumanager/cpu_manager.go`

---

## KubeVirt Issues (fixed in `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1`)

### 4. `copyResourceClaims` deduplicates by Name only

**Symptom:** NIC request dropped from multi-device claim when GPU and NIC are in the same ResourceClaim. The compute container only gets CDI devices for the GPU, not the NIC.

**Root cause:** `copyResourceClaims` in `renderresources.go` deduplicates claim references by `Name` only. When a claim has multiple requests (gpu, nic, nvme, cpu, mem), the second reference with the same claim Name is dropped.

**Fix:** Deduplicate by `{Name, Request}` tuple instead of just `Name`.

**File:** `pkg/virt-controller/services/renderresources.go`

---

### 5. `WithExtraResourceClaims` doesn't add all VMI claims

**Symptom:** Kubelet doesn't inject CDI devices for some DRA requests (e.g., CPU, memory, NVMe). Only GPU and NIC devices appear in the container.

**Root cause:** `WithExtraResourceClaims` only added claims that weren't already referenced by GPU or host device entries. But the GPU/hostDevice code only referenced specific requests, not all requests in the claim. Claims with unreferenced requests (cpu, mem) were skipped.

**Fix:** `WithExtraResourceClaims` now adds every VMI claim to the compute container's `resources.claims` without a Request filter.

**File:** `pkg/virt-controller/services/renderresources.go`

---

### 6. `WithGPUsDRA`/`WithHostDevicesDRA` cause duplicate claim name errors

**Symptom:** Pod creation fails with k8s API validation error: `Duplicate value` for claim names in `resources.claims`.

**Root cause:** Both `WithGPUsDRA` and `WithHostDevicesDRA` added per-request claim references, but `WithExtraResourceClaims` also adds blanket references for all claims. The k8s API rejects duplicate claim names.

**Fix:** Simplified `WithGPUsDRA` and `WithHostDevicesDRA` to no-ops — all claim references come through `WithExtraResourceClaims`.

**File:** `pkg/virt-controller/services/renderresources.go`

---

### 7. `guestMappingPassthrough` maps memory to wrong NUMA node

**Symptom:** QEMU fails with `set_mempolicy: Invalid argument` / `cannot bind memory to host NUMA nodes`. The QEMU command shows `host-nodes:[1]` (NUMA 1) but CPUs are pinned to NUMA 0.

**Root cause:** virt-launcher's `GetPodCPUSet()` reads `cpuset.cpus.effective` from its own cgroup. If the kubelet hasn't corrected the cpuset yet (see kubelet issue #3), virt-launcher gets the wrong CPU list, maps them to the wrong host NUMA cell, and generates QEMU memory bindings for the wrong NUMA node.

**Fix:** Fixed on the kubelet side (issue #3). The cpuset is now correct before the container process starts. No KubeVirt code change needed, but virt-launcher is fragile — it reads cpuset once and caches it, with no retry or validation.

**Potential upstream improvement:** virt-launcher could validate that the cpuset CPUs are consistent with the cgroup's `cpuset.mems`, or retry reading cpuset if it detects a mismatch.

---

## DRA Driver Issues

### 8. SR-IOV DRA driver: no KEP-5304 pciBusID metadata

**Symptom:** KubeVirt VM fails with `HostDevice nic0 has no mdevUUID or pciBusID in metadata for claim numa0 request nic`.

**Root cause:** The `sriovnetwork.k8snetworkplumbingwg.io` DRA driver doesn't set `Device.Metadata` with `resource.kubernetes.io/pciBusID` in `PrepareResult`. KubeVirt needs this to create VFIO passthrough entries in the VM's domain XML.

**Workaround:** Use dranet instead — it publishes KEP-5304 metadata with pciBusID. However, dranet NIC VFIO requires the full VFIO feature branch (`johnahull/dranet` `feature/standardized-topology-attrs`).

**Status:** Not fixed upstream. The SR-IOV DRA driver would need to opt into KEP-5304 and publish device metadata in `PrepareResult`.

---

### 9. dra-driver-nvme: checkpoint race and VFIO lifecycle bugs

**Symptom:** Multiple code quality issues found during code review.

**Issues fixed (committed to `johnahull/dra-driver-nvme` main):**
- Checkpoint save: shallow copy of prepared map without lock protection (race condition)
- Checkpoint restore: assigned to `s.prepared` without holding mutex
- VFIO unbind failure: early return prevented rebind to nvme driver (device leak)
- VFIO bind failure: didn't clear `driver_override` or attempt driver restoration
- No checkpoint persistence at all (added)
- No structured logging (switched to `klog.InfoS` / `klog.FromContext`)
- No tests (added unit tests for api and pkg/nvme)
- No rolling update support (added `kubeletplugin.RollingUpdate`)
- No fatal error propagation (added `cancelMainCtx` pattern)

---

### 10. VFIO passthrough fails in non-root mode: libvirt prlimit requires CAP_SYS_RESOURCE

**Symptom:** VM with VFIO GPU passthrough fails with `cannot limit locked memory of process 111 to 9007199254740991: Operation not permitted`. Affects both DRA and device-plugin provisioned devices when the `Root` feature gate is not enabled (the default).

**Root cause:** virt-handler's external `prlimit64` on virtqemud works correctly — `IsVFIOVMI` returns true, `FindVirtqemudProcess` finds the process, and `SetProcessMemoryLockRLimit` succeeds (confirmed via verbosity 5 logs: `Cur: 18572378928 Max:18572378928`). However, libvirt inside the container makes a **second** `prlimit()` call — `virProcessSetMaxMemLock()` calls `prlimit(QEMU_pid, RLIMIT_MEMLOCK, 2^53-1)` from virtqemud on the QEMU child process. The Linux kernel requires `CAP_SYS_RESOURCE` for `prlimit()` on another process, regardless of whether the value is being raised or lowered. In non-root mode, the container has only `NET_BIND_SERVICE` with `Drop: ["ALL"]` — no `CAP_SYS_RESOURCE`.

**Fix:** Two changes scoped to VFIO VMIs only:
1. virt-api webhook (`vmi-mutator.go`): skip `markAsNonroot()` when `IsVFIOVMI(vmi)` is true
2. virt-controller (`rendercontainer.go`): add `CAP_SYS_RESOURCE` for VFIO VMIs

Non-VFIO VMs remain non-root with minimal capabilities.

**Issue:** [kubevirt/kubevirt#17694](https://github.com/kubevirt/kubevirt/issues/17694)
**PR:** [kubevirt/kubevirt#17696](https://github.com/kubevirt/kubevirt/pull/17696) (draft)
**Related:** [#12433](https://github.com/kubevirt/kubevirt/issues/12433), [#10379](https://github.com/kubevirt/kubevirt/issues/10379), [harvester#9059](https://github.com/harvester/harvester/issues/9059), [cozystack#1367](https://github.com/cozystack/cozystack/issues/1367)

**Files:** `pkg/virt-api/webhooks/mutating-webhook/mutators/vmi-mutator.go`, `pkg/virt-controller/services/rendercontainer.go`, `pkg/virt-controller/services/template.go`

---

## Summary

| # | Component | Severity | Status |
|---|-----------|----------|--------|
| 1 | Kubelet: DRA topology hints field selector | High | Fixed, pushed |
| 2 | Kubelet: CPU manager reconciler race | High | Fixed, pushed |
| 3 | Kubelet: CPU manager cpuset timing | High | Fixed, pushed |
| 4 | KubeVirt: copyResourceClaims dedup | High | Fixed in fork |
| 5 | KubeVirt: WithExtraResourceClaims filter | High | Fixed in fork |
| 6 | KubeVirt: duplicate claim name errors | Medium | Fixed in fork |
| 7 | KubeVirt: guestMappingPassthrough wrong NUMA | High | Fixed via kubelet #3 |
| 8 | SR-IOV DRA driver: no KEP-5304 metadata | Medium | Not fixed, use dranet |
| 9 | dra-driver-nvme: multiple bugs | Medium | Fixed, pushed |
| 10 | KubeVirt: VFIO non-root memlock prlimit | High | Draft PR [#17696](https://github.com/kubevirt/kubevirt/pull/17696) |

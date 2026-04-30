# Issues Tracker

Running list of issues to fix across all repos. Updated as PRs are opened/merged.

---

## Open

### Kubelet

#### CPU pinning with DRA devices — two options

DRA scheduling co-places GPUs, NICs, and other devices on the same NUMA node, but CPU pinning is handled separately by the kubelet. Without coordination, CPUs may be pinned to a different NUMA node than the DRA devices. There are two mutually exclusive approaches to solve this:

**Option A: DRA CPU driver (`cpuManagerPolicy: none`)**

The DRA CPU driver (`kubernetes-sigs/dra-driver-cpu`) allocates CPUs as DRA devices in the same ResourceClaim as GPUs and NICs. A single `matchAttribute: numaNode` constraint aligns all resource types at scheduling time. The CPU driver pins via NRI `CreateContainer` hook. The kubelet CPU manager is disabled.

- **Branch:** uses upstream `dra-driver-cpu` with `feature/standardized-topology-attrs` for numaNode
- **What needs patching:**
  - `dra-driver-cpu` — publish `resource.kubernetes.io/numaNode` (our `feature/standardized-topology-attrs` branch; upstream publishes `dra.cpu/numaNodeID` only)
  - KubeVirt — needs a way to request CPUs via DRA claim instead of (or alongside) `dedicatedCpuPlacement`
  - No kubelet patches needed
- **Pros:** one system, one constraint, guaranteed NUMA alignment at scheduling time. No kubelet patches.
- **Cons:** KubeVirt `dedicatedCpuPlacement` API doesn't know about DRA CPU claims. Extra DRA driver daemonset. `cpuManagerPolicy: none` disables kubelet CPU pinning for all pods — in practice this only matters on mixed-use nodes where non-DRA pods also need exclusive CPUs (e.g., DPDK, real-time). On dedicated GPU nodes (typical deployment), all CPU-pinned workloads use DRA and this isn't an issue.
- **Status:** running on Dell R760xa

**Option B: Kubelet DRA topology hints (`cpuManagerPolicy: static`)**

The kubelet CPU manager stays. A new `HintProvider` in the DRA Manager reads `numaNode` from ResourceSlice attributes for each DRA device and returns topology hints. The topology manager merges these with CPU manager hints to pin CPUs to the same NUMA node as DRA devices.

- **Branch:** `johnahull/kubernetes` `feature/dra-topology-hints`
- **What needs patching:**
  - Kubelet `pkg/kubelet/cm/dra/topology_hints.go` (new) — DRA Manager implements `HintProvider`, reads `numaNode` from ResourceSlice
  - Kubelet `pkg/kubelet/cm/dra/manager.go` — register DRA Manager as topology hint provider, add `nodeName` field
  - Kubelet `pkg/kubelet/cm/container_manager_linux.go` — wire DRA Manager into topology manager
  - Kubelet `pkg/kubelet/cm/cpumanager/cpu_manager.go` — fix cpuset reconciler race (K-2) and apply cpuset before container starts (K-3)
  - No DRA driver patches needed
  - No KubeVirt patches needed (existing `dedicatedCpuPlacement` works as-is)
- **Pros:** works with existing KubeVirt `dedicatedCpuPlacement`. No extra driver. Non-DRA pods still get kubelet CPU pinning.
- **Cons:** patched kubelet (not upstream). Two systems coordinating (DRA scheduler + topology manager). Topology manager hints are best-effort. Required CPU manager bug fixes (K-2, K-3) to work reliably.
- **Status:** running on Dell R760xa

**Which option is active depends on `cpuManagerPolicy`:**
- `cpuManagerPolicy: none` (default) → option A. The kubelet CPU manager is disabled. Deploy the DRA CPU driver to handle CPU allocation and pinning via NRI. Topology hints are harmless but unused.
- `cpuManagerPolicy: static` → option B. The kubelet CPU manager is active. DRA topology hints guide it to pin CPUs on the same NUMA as DRA devices. Don't deploy the DRA CPU driver — the kubelet owns CPU pinning.

A single kubelet binary with the topology hints patch supports both paths. The deployment decides which option to use based on `cpuManagerPolicy` and whether the DRA CPU driver is deployed.

**Key difference: guaranteed vs best-effort.** Option A is guaranteed — the scheduler either finds a node where all resources (GPU + NIC + CPU) match on the same NUMA and schedules there, or the pod stays pending. There's no silent degradation. Option B is best-effort — the topology manager may ignore DRA hints if they conflict with other hint providers (memory manager, other device plugins), silently placing CPUs on a different NUMA than the DRA devices. Option A is the stronger long-term path for this reason.

---

#### K-1: DRA topology hints — kubelet doesn't provide NUMA hints for DRA devices

**Repo:** `kubernetes/kubernetes`
**Fix:** `johnahull/kubernetes` `feature/dra-topology-hints`
**Files:** `pkg/kubelet/cm/dra/topology_hints.go` (new), `pkg/kubelet/cm/dra/manager.go`, `pkg/kubelet/cm/container_manager_linux.go`

The kubelet's topology manager coordinates CPU pinning by collecting NUMA hints from all registered HintProviders (CPU manager, device manager, etc.). DRA devices are not covered — the DRA Manager doesn't implement the `topologymanager.HintProvider` interface. This means when DRA allocates a GPU on NUMA 0, the topology manager doesn't know about it, and the CPU manager may pin vCPUs to NUMA 1.

The fix adds `topology_hints.go` where the DRA Manager implements `HintProvider`. For each device in the pod's ResourceClaim allocations, it looks up `resource.kubernetes.io/numaNode` from the device's ResourceSlice attributes and returns a topology hint with the corresponding `NUMANodeAffinity`. The topology manager then merges these hints with the CPU manager's hints to select the best NUMA node for CPU pinning.

A critical requirement: the `ResourceSlices().List()` call must include `FieldSelector: "spec.nodeName=" + m.nodeName`. The kubelet's Node Authorizer denies unscoped ResourceSlice list requests with `DecisionNoOpinion`, which falls through to RBAC denial. Without the field selector, the list silently returns empty and no hints are generated. The error was logged at V(4), invisible at default kubelet verbosity.

The `Manager` struct gains a `nodeName` field, passed from `container_manager_linux.go` via `string(nodeConfig.NodeName)`. The DRA Manager is registered as a HintProvider with `cm.topologyManager.AddHintProvider(logger, cm.draManager)`.

---

#### K-2: CPU manager reconciler never corrects cgroup cpuset mismatches

**Repo:** `kubernetes/kubernetes`
**Fix:** `johnahull/kubernetes` `feature/enforcement-preferred` commit `77a449e`
**File:** `pkg/kubelet/cm/cpumanager/cpu_manager.go`

The CPU manager's reconciliation loop runs every 10 seconds and is supposed to detect and correct any cgroup cpuset that doesn't match the desired state. It compares the desired cpuset (`state.GetCPUSetOrDefault`) against a `lastUpdateState` value that tracks what was last written to the cgroup. If they match, it skips the update.

The bug: `AddContainer()` set `lastUpdateState` to the desired cpuset immediately, without ever calling `updateContainerCPUSet` to write the cgroup. This told the reconciler "I already applied this cpuset" even though the cgroup was never updated. If containerd or any other component wrote a different cpuset to the cgroup after container creation, the reconciler would never notice — `desired == lastUpdate` was always true, so `updateContainerCPUSet` was never called.

On the R760xa, the compute container's cgroup showed all odd CPUs (NUMA 1) while `cpu_manager_state` showed CPUs 4,6,68,70 (NUMA 0). The mismatch persisted indefinitely.

The fix removes the `lastUpdateState` pre-population from `AddContainer()`. Instead, `AddContainer()` now calls `updateContainerCPUSet()` directly (see K-3), and only sets `lastUpdateState` after a successful write. The reconciler can then detect any subsequent mismatches because `lastUpdateState` accurately reflects what was written.

---

#### K-3: CPU manager cpuset not applied before container starts

**Repo:** `kubernetes/kubernetes`
**Fix:** `johnahull/kubernetes` `feature/enforcement-preferred` commit `77a449e`
**File:** `pkg/kubelet/cm/cpumanager/cpu_manager.go`

The kubelet's `PreCreateContainer` callback sets `CpusetCpus` in the CRI container config before calling `CreateContainer`. Containerd is supposed to create the container with that cpuset. However, containerd doesn't reliably apply the `CpusetCpus` field during container creation — the container starts with a cpuset inherited from the pod-level cgroup instead of the dedicated CPU assignment.

The container lifecycle is:
1. `PreCreateContainer` — sets `CpusetCpus = "4,6,68,70"` in CRI config
2. `CreateContainer` — containerd creates the container (cpuset may not be applied)
3. `PreStartContainer` — kubelet calls `AddContainer()`
4. `StartContainer` — container process starts
5. Reconciler (async, 10s period) — would eventually correct the cpuset

Without the fix, the container starts at step 4 with the wrong cpuset. KubeVirt's virt-launcher reads `cpuset.cpus.effective` immediately at startup (in `GetPodCPUSet()`), gets the wrong CPU list, maps them to the wrong host NUMA cell, and generates QEMU memory bindings for NUMA 1 instead of NUMA 0. QEMU then crashes with `set_mempolicy: Invalid argument` because `cpuset.mems` only allows NUMA 0 but the memory binding targets NUMA 1.

The fix adds a `updateContainerCPUSet()` call in `AddContainer()`, which runs during step 3 (`PreStartContainer`) — after the container is created but before it starts. This ensures the cgroup cpuset is correct before the container process begins. The update only triggers for small dedicated cpusets (< 128 CPUs) to avoid unnecessarily updating containers that use the default set.

---

### KubeVirt

#### KV-1: `copyResourceClaims` deduplicates by Name only

**Repo:** `kubevirt/kubevirt`
**Fix:** `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1`
**File:** `pkg/virt-controller/services/renderresources.go`

When the virt-controller creates the virt-launcher pod spec, it copies resource claim references from the VMI spec to the pod's container resources. The `copyResourceClaims` function deduplicates these references to avoid Kubernetes API validation errors on duplicate claim names.

The bug: deduplication uses only the claim `Name` field. When a single ResourceClaim has multiple requests (e.g., `gpu`, `nic`, `nvme`, `cpu`, `mem` all in one claim), each GPU/hostDevice entry references the same claim Name with a different Request. The first reference is kept and subsequent references with the same Name are dropped — even though they have different Request values. This causes the kubelet to only inject CDI devices for the first request, silently dropping all other devices from the claim.

The fix changes the deduplication key from `Name` to `{Name, Request}`, preserving all unique request references.

---

#### KV-2: `WithExtraResourceClaims` skips claims already referenced by GPU/hostDevice

**Repo:** `kubevirt/kubevirt`
**Fix:** `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1` commit `595bdfb`
**File:** `pkg/virt-controller/services/renderresources.go`

The `WithExtraResourceClaims` function adds VMI resource claims to the compute container's `resources.claims` list. Its purpose is to ensure DRA CPU and memory claims (which aren't referenced by GPU or hostDevice entries) get added so the kubelet processes them.

The bug: it builds a `referenced` map of claim names that are already handled by `WithGPUsDRA` or `WithHostDevicesDRA`, and skips those. But those functions only add specific request references (e.g., the `gpu` request), not all requests in the claim. When a claim has 5 requests (gpu, nic, nvme, cpu, mem) and the GPU function references it, `WithExtraResourceClaims` skips the entire claim — leaving the cpu, mem, nic, and nvme requests without any pod-level reference. The kubelet never injects CDI devices for those requests.

The fix removes the `referenced` filter entirely. `WithExtraResourceClaims` now adds every VMI claim to the compute container without checking whether it's already referenced. The kubelet deduplicates CDI device IDs internally, so adding a claim that's already referenced by a specific request is safe.

---

#### KV-3: `WithGPUsDRA`/`WithHostDevicesDRA` cause duplicate claim name API errors

**Repo:** `kubevirt/kubevirt`
**Fix:** `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1` commit `595bdfb`
**File:** `pkg/virt-controller/services/renderresources.go`

`WithGPUsDRA` and `WithHostDevicesDRA` each add per-request claim references (e.g., `{Name: "numa0", Request: "gpu"}`). `WithExtraResourceClaims` adds blanket references (e.g., `{Name: "numa0"}`). When both run, the pod spec ends up with two entries for the same claim Name. The Kubernetes API rejects this with a `Duplicate value` validation error.

The fix simplifies `WithGPUsDRA` and `WithHostDevicesDRA` to no-ops — they no longer add claim references. All claim references come through `WithExtraResourceClaims`, which adds each claim once without a specific request filter. The kubelet handles request-level CDI injection internally based on the claim's allocation results.

---

#### KV-4: `guestMappingPassthrough` fragile — reads cpuset once at startup

**Repo:** `kubevirt/kubevirt`
**Fix:** Workaround via kubelet fix K-3. No KubeVirt code change yet.

KubeVirt's virt-launcher reads the container's `cpuset.cpus.effective` once at startup via `GetPodCPUSet()` in `pkg/virt-launcher/virtwrap/util/cpu_utils.go`. This value is used to determine which host CPUs are available, which host NUMA cells they belong to, and how to map guest NUMA nodes to host NUMA nodes. The value is cached and never re-read.

If the cpuset is incorrect when virt-launcher reads it (see K-3), the entire NUMA mapping is wrong. The `numaMapping()` function in `vcpu.go` maps vCPU pins to host NUMA cells via `involvedCells()`, then creates `NUMATune.MemNode` entries with the wrong `NodeSet`. QEMU tries to bind hugepage memory to a NUMA node that's not allowed by `cpuset.mems`, and crashes.

The kubelet fix K-3 ensures the cpuset is correct before the container starts, which resolves this for new pods. But virt-launcher remains fragile — a cgroup modification by any external component after startup would go undetected. A proper fix would have virt-launcher validate that `cpuset.cpus` and `cpuset.mems` are consistent (all CPUs should be on NUMA nodes allowed by mems), or retry reading the cpuset if it detects an inconsistency.

---

#### KV-5: VEP 115 reads device NUMA from sysfs only, not from DRA KEP-5304 metadata

**Repo:** `kubevirt/kubevirt`
**Fix:** `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1`

KubeVirt's PCI NUMA-Aware Topology feature (VEP 115) determines each passthrough device's NUMA node by reading the host's `/sys/bus/pci/devices/<BDF>/numa_node` file. This works for device-plugin devices where the PCI address is known from the device plugin API, but it doesn't work for DRA devices where the PCI address comes from KEP-5304 metadata files.

The patched KubeVirt reads `resource.kubernetes.io/pciBusID` and `numaNode` from the KEP-5304 metadata directory (`/var/run/kubernetes.io/dra-device-attributes/`) and uses those values to place devices on the correct guest NUMA node via `pxb-pcie` expander buses. This is the bridge between DRA's device metadata API and KubeVirt's guest topology construction.

This needs an upstream proposal to add DRA metadata support to VEP 115.

---

#### KV-6: ACPI not auto-enabled when guest NUMA topology is used

**Repo:** `kubevirt/kubevirt`
**Fix:** Not yet implemented.

When `guestMappingPassthrough` creates multi-NUMA guest topology with `pxb-pcie` expander buses, the guest OS needs ACPI to discover the NUMA topology via SRAT/SLIT tables. If ACPI is not enabled in the VM spec, the guest sees all devices on NUMA node 0 regardless of the pxb-pcie placement.

KubeVirt should auto-enable ACPI when guest NUMA topology is configured, or at minimum warn when NUMA passthrough is used without ACPI.

---

### DRA Drivers

#### D-1: SR-IOV DRA driver has no KEP-5304 `pciBusID` metadata

**Repo:** `k8snetworkplumbingwg/dra-driver-sriov`
**Fix:** Not started. Workaround: use dranet.

The SR-IOV DRA driver (`sriovnetwork.k8snetworkplumbingwg.io`) publishes device attributes in ResourceSlices but doesn't set `Device.Metadata` in `PrepareResult` with KEP-5304 device metadata. KubeVirt's virt-launcher needs `resource.kubernetes.io/pciBusID` in the metadata to create VFIO passthrough entries in the VM's domain XML.

Without this metadata, KubeVirt fails with: `HostDevice nic0 has no mdevUUID or pciBusID in metadata for claim numa0 request nic`.

The workaround is to use dranet instead, which publishes KEP-5304 metadata with `pciBusID`. The SR-IOV driver would need to opt into KEP-5304 by calling `kubeletplugin.EnableDeviceMetadata(true)` and populating `DeviceMetadata.Attributes` in `PrepareResult`.

---

#### D-2: NVIDIA GPU DRA driver: `numaNode` not published for standard GPU devices

**Repo:** `NVIDIA/k8s-dra-driver-gpu`
**Fix:** `johnahull/dra-driver-nvidia-gpu` `feature/standardized-topology-attrs`

The NVIDIA DRA driver publishes `resource.kubernetes.io/numaNode` for VFIO-type GPU devices but not for standard (compute) GPU devices. This means `matchAttribute: resource.kubernetes.io/numaNode` constraints only work when requesting VFIO GPUs, not standard GPUs.

The fix adds `resource.kubernetes.io/numaNode` and `cpuSocketID` to all GPU device types (standard, MIG, VFIO) in the ResourceSlice.

---

#### D-3: NVIDIA GPU DRA driver: KEP-5304 opt-in not yet available

**Repo:** `NVIDIA/k8s-dra-driver-gpu`
**Fix:** Upstream issue [#916](https://github.com/NVIDIA/k8s-dra-driver-gpu/issues/916), targeting v26.4.0.

The NVIDIA DRA driver doesn't yet publish KEP-5304 device metadata in `PrepareResult`. KubeVirt needs `resource.kubernetes.io/pciBusID` in the metadata to create VFIO passthrough entries. Without it, KubeVirt can't determine the PCI address of DRA-allocated GPUs.

The NVIDIA driver currently publishes PCI addresses only in ResourceSlice attributes (which are visible to the scheduler but not to the pod). KEP-5304 bridges this gap by projecting device attributes into the pod as files.

---

#### D-4: dranet VFIO support not upstream

**Repo:** `kubernetes-sigs/dranet`
**Fix:** `johnahull/dranet` `feature/standardized-topology-attrs`

dranet (the upstream k8s-sigs DRA network driver) only supports container networking today — attaching NICs to pod network namespaces via NRI. VFIO passthrough support (binding NIC VFs to `vfio-pci` for KubeVirt VM use cases) exists in the fork but hasn't been proposed upstream.

The implementation adds:
- `Mode` field to `NetworkConfig` (`"netdev"` default vs `"vfio"`)
- VFIO sysfs bind/unbind operations
- CDI spec generation for `/dev/vfio/*` device nodes
- VFIO branch in `prepareResourceClaim` with rollback on failure
- Skip VFIO devices in NRI hooks (no network namespace operations)
- Driver restore in `unprepareResourceClaim`

---

#### D-5: dranet standardized topology attributes not upstream

**Repo:** `kubernetes-sigs/dranet`
**Fix:** `johnahull/dranet` `feature/standardized-topology-attrs`

dranet publishes NIC devices with vendor-specific topology attributes (`dra.net/numaNode`) but not the standardized `resource.kubernetes.io/numaNode`, `cpuSocketID`, `pciBusID`, or `pcieRoot` attributes needed for cross-driver `matchAttribute` constraints.

The fork adds all four standardized attributes to every discovered NIC device, alongside the existing vendor-specific attributes. It also ensures `isSriovVf` is set on all devices (was only set on VFs, causing CEL `no such key` crashes when used in DeviceClass selectors).

---

### Kubernetes Upstream

#### U-1: `enforcement: Preferred` not in upstream API

**Repo:** `kubernetes/kubernetes`
**Fix:** `johnahull/kubernetes` `feature/enforcement-preferred` (3 commits)

The DRA scheduler's `matchAttribute` constraint is all-or-nothing — if the constraint can't be satisfied, the pod is unschedulable. On hardware where not all devices share a PCIe root (e.g., R760xa where every device has its own root), a `matchAttribute: resource.kubernetes.io/pcieRoot` constraint is unsatisfiable. Users need a way to express "prefer tight coupling but accept looser coupling."

The fix adds an `Enforcement` field to `DeviceConstraint` with two values: `Required` (default, current behavior) and `Preferred` (skip if unsatisfiable). This enables a two-level hierarchy: prefer `pcieRoot` (same switch), require `numaNode` (same memory controller).

Three commits implement this:
1. API type + validation + protobuf + OpenAPI generation
2. Feature gate `DRAListTypeAttributes` enabled by default
3. Allocator skips preferred constraints when they can't be satisfied

All five Kubernetes binaries (apiserver, scheduler, controller-manager, kubelet, kubectl) must be built from this branch to preserve the `enforcement` field through the entire claim lifecycle.

---

#### U-2: Standardized `resource.kubernetes.io/numaNode` not agreed

**Repo:** `kubernetes/kubernetes`
**Fix:** [Proposal](docs/upstream-proposals/standardize-numanode.md). Discussed in SIG-Node.

Each DRA driver publishes NUMA information under its own vendor-specific attribute name (`gpu.nvidia.com/numa`, `dra.cpu/numaNodeID`, `dra.net/numaNode`, etc.). For cross-driver `matchAttribute` constraints to work, all drivers must use the same attribute name.

The proposal recommends `resource.kubernetes.io/numaNode` (int) as a standardized attribute, with a helper function in the `deviceattribute` library to derive the value from sysfs. The `resource.kubernetes.io/` prefix signals that this is a well-known attribute with defined semantics, not vendor-specific data. `cpuSocketID` is not part of the core proposal — it can be published by drivers independently if needed.

Until this is agreed upstream, each driver fork publishes both the vendor-specific and standardized attributes.

---

#### U-3: `deviceattribute` library: `GetPCIeRootAttributeMapFromCPUId` helper

**Repo:** `kubernetes/kubernetes`
**Fix:** [PR #138297](https://github.com/kubernetes/kubernetes/pull/138297) (WIP)

The `deviceattribute` library provides helpers like `GetPCIBusIDAttribute()` and `GetPCIeRootAttributeByPCIBusID()` for DRA drivers to derive topology attributes from sysfs. A missing helper is `GetPCIeRootAttributeMapFromCPUId()`, which would let non-PCI drivers (CPU, memory) publish `pcieRoot` attributes by mapping their NUMA node to the PCIe root complexes on that node.

This is needed for the distance hierarchy (U-1) where CPU and memory drivers need to participate in `matchAttribute: resource.kubernetes.io/pcieRoot` constraints.

#### D-8: AMD GPU DRA driver: `numaNode` attribute not standardized

**Repo:** `ROCm/k8s-gpu-dra-driver`
**Fix:** `johnahull/k8s-gpu-dra-driver` `feature/standardized-topology-attrs`

The AMD driver publishes `numaNode` as a bare unqualified attribute (no domain prefix). PR #36 (merged 2026-04-16) cleaned up attribute names and added `resource.kubernetes.io/pciBusID` via the `deviceattribute` library, but left `numaNode` as bare `"numaNode"`. This won't match `matchAttribute: resource.kubernetes.io/numaNode` from other drivers, breaking cross-driver NUMA alignment.

The fork adds `resource.kubernetes.io/numaNode` and `resource.kubernetes.io/cpuSocketID` alongside the bare attributes.

---

### Topology Coordinator

#### TC-1: 6 bug-fix patches not merged upstream

**Repo:** `fabiendupont/k8s-dra-topology-coordinator`
**Fix:** `johnahull/k8s-dra-topology-coordinator` branches: `fix/distance-based-fallback`, `fix/numanode-attribute-namespace`, `fix/pcieroot-constraint-non-pci-drivers`, `fix/per-driver-cel-selectors`, `fix/webhook-forward-cel-selectors`, `test/all-fixes-combined`

Six independent bug fixes for the topology coordinator POC:
1. **Label truncation** — DeviceClass names exceed 63-char label limit
2. **Attribute namespace** — NUMA attribute uses wrong per-driver namespace in CEL selectors
3. **CEL selector forwarding** — user-defined CEL selectors on the original DeviceClass not forwarded to partition sub-classes
4. **pcieRoot filtering** — non-PCI drivers (CPU, memory) fail pcieRoot constraint evaluation
5. **Distance-based fallback** — pcieRoot → numaNode fallback with `CouplingLevel` abstraction
6. **Webhook CEL selectors** — webhook expansion doesn't pass CEL selectors from the original claim

All fixes are in separate branches for independent review. Combined branch `test/all-fixes-combined` passes all tests.

---

#### TC-2: Webhook unavailable during controller restarts

**Repo:** `fabiendupont/k8s-dra-topology-coordinator`
**Fix:** Not started.

The topology coordinator runs a mutating admission webhook that expands simple "partition" claims into multi-driver NUMA-aligned requests. During controller pod restarts, the webhook is unavailable and new claims fail. This needs either a webhook failurePolicy change, a readiness gate, or a fallback path.

---

### DRA Drivers (additional)

#### D-6: AMD GPU DRA driver: VFIO bind/unbind lifecycle missing

**Repo:** `ROCm/k8s-gpu-dra-driver`
**Fix:** `johnahull/k8s-gpu-dra-driver` `feature/vfio-passthrough`

The AMD GPU DRA driver discovers GPUs but doesn't support VFIO passthrough. For KubeVirt VM use cases, the driver needs to unbind GPUs from the `amdgpu` kernel driver, bind to `vfio-pci`, generate CDI specs for `/dev/vfio/*` device nodes, and handle IOMMU groups. Additionally, GPU discovery breaks after VFIO unbind because the driver reads GPU attributes from sysfs files that disappear when the native driver is unbound.

The fork adds VFIO config support, discovery caching before unbind, and CDI spec generation.

---

#### D-7: AMD GPU DRA driver: KEP-5304 metadata opt-in

**Repo:** `ROCm/k8s-gpu-dra-driver`
**Fix:** `johnahull/k8s-gpu-dra-driver` `feat/kep5304-device-metadata`

The AMD driver publishes `resource.kubernetes.io/pciBusID` in ResourceSlice attributes (on main), but doesn't opt into KEP-5304 device metadata in `PrepareResult`. KubeVirt needs the PCI address projected into the pod as a metadata file, not just visible to the scheduler.

The fork adds `kubeletplugin.EnableDeviceMetadata(true)` and populates `DeviceMetadata.Attributes` with `pciBusID` and `numaNode` in the prepare path.

---

### Kubelet (additional)

#### K-4: Multi-driver claims may only inject KEP-5304 metadata for one driver

**Repo:** `kubernetes/kubernetes`
**Fix:** Possibly fixed on main. Needs retest.

When a ResourceClaim contains devices from multiple DRA drivers (e.g., GPU + NIC + CPU + memory), the kubelet's metadata writer may only generate metadata files for one driver's devices. The code in `metadataWriter.processPreparedClaim` iterates `Device.Requests` to associate devices with request names — if `Device.Requests` is not set by a driver, its metadata files are never written.

This was observed with the dranet driver before `Device.Requests` was added to the `PrepareResult`. The upstream kubelet code has since been restructured to aggregate CDI IDs from all drivers per claim, but this needs retesting to confirm the metadata injection works for multi-driver claims end-to-end.

---

### KubeVirt (additional)

#### KV-7: virt-controller missing VFIO capabilities for DRA host device pods

**Repo:** `kubevirt/kubevirt`
**Fix:** `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.1`

When DRA host devices are passed through via VFIO, the virt-launcher pod needs capabilities for DMA memory locking: `SYS_RESOURCE`, `IPC_LOCK`, and unlimited memlock rlimits. The virt-controller's pod template renderer doesn't add these for DRA-allocated devices (only for device-plugin devices where `permittedHostDevices` entries specify VFIO requirements).

The fork adds these capabilities when DRA host devices or GPUs are present in the VMI spec. The `ReservedOverheadMemlock` feature gate controls the memlock reservation via `reservedOverhead.addedOverhead` in the VM spec.

---

## Closed

| # | Issue | Closed By | Notes |
|---|-------|-----------|-------|
| — | AMD GPU DRA driver publishes standard `pciBusID` | `ROCm/k8s-gpu-dra-driver` main | Now uses `deviceattribute.GetPCIBusIDAttribute()` |
| — | AMD GPU DRA driver publishes `numaNode` for all device types | `ROCm/k8s-gpu-dra-driver` main | Published for full GPUs and partitions, but as bare `numaNode` — see D-8 |
| — | AMD GPU DRA driver version fallback + multi-driver claim filter | [ROCm/k8s-gpu-dra-driver#45](https://github.com/ROCm/k8s-gpu-dra-driver/pull/45) | `GetDriverVersion()` returns `"0.0.0"` for in-kernel amdgpu |
| — | NVIDIA GPU DRA driver VFIO `/host-root` mount validation | [kubernetes-sigs/dra-driver-nvidia-gpu#1077](https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1077) | Validate mount at startup, improve error messages |
| — | KubeVirt `permittedHostDevices` blocks DRA devices | `kubevirt/kubevirt` main | `HostDevicesWithDRA` feature gate (alpha) skips validation |

#### D-9: DRA CPU driver NRI plugin conflicts with kubelet CPU manager on dedicated pods

**Repo:** `kubernetes-sigs/dra-driver-cpu`
**Fix:** Not started. Workaround: needs investigation.

When a pod has `dedicatedCpuPlacement: true`, the kubelet's CPU manager allocates exclusive CPUs and sets the cgroup cpuset. The DRA CPU driver's NRI plugin also tries to restrict the pod's CPUs based on the `dra.cpu/cpu` capacity of the allocated CPU device (e.g., 64 CPUs for a whole NUMA node). This fails with "not enough cpus available to satisfy request: requested=64, available=0" because the NRI plugin can't find available CPUs — the kubelet has already allocated them.

The DRA CPU device should be a NUMA marker for scheduling purposes (to participate in `matchAttribute: resource.kubernetes.io/numaNode`), not an actual CPU allocator. When the kubelet CPU manager handles CPU placement, the DRA CPU driver's NRI plugin should not attempt to restrict CPUs.

Observed on XE8640 with KubeVirt VMs using `dedicatedCpuPlacement`. Not observed on R760xa (possibly different DRA CPU driver version or NRI behavior).


#### D-10: NVIDIA DRA driver lock contention causes deadlock during VFIO prepare

**Repo:** `NVIDIA/k8s-dra-driver-gpu` (upstream bug)
**Fix:** Not started. Workaround: clean state between attempts.

The NVIDIA DRA driver acquires a file-based flock (`pu.lock`) for the entire duration of `PrepareResourceClaims`, including `WaitForGPUFree` which shells out to `fuser` via chroot. If the prepare takes longer than the kubelet's DRA timeout (~30s), the kubelet reports `DeadlineExceeded` and retries. But the previous prepare is still holding the lock, so all subsequent attempts fail with "timeout acquiring lock."

This creates a deadlock: the lock holder is stuck in `WaitForGPUFree`, and the kubelet can't unprepare old claims because unprepare also needs the same lock. New prepare attempts are blocked too.

Observed on XE8640 with H100 SXM5 GPUs. Not observed on R760xa with A40 GPUs (possibly different `WaitForGPUFree` timing or fewer device nodes to check).

Correct fix: narrow the lock scope to exclude `WaitForGPUFree`, or use a per-claim lock instead of a global lock, or increase the timeout.


#### D-11: H100 SXM5 VFIO requires Fabric Manager FABRIC_MODE=1 and boot-time GPU binding

**Repo:** NVIDIA GPU Operator / Fabric Manager configuration
**Fix:** Not started. Requires boot-time GPU configuration + Fabric Manager.

On H100 SXM5 systems (HGX platforms with NVLink), the nvidia kernel driver's sysfs unbind blocks indefinitely because unbinding one GPU triggers NVLink fabric reconfiguration that deadlocks. This makes runtime GPU rebinding from nvidia to vfio-pci impossible. Repeated bind/unbind cycles also corrupt the driver state, causing nvidia-smi to report "No devices were found."

**Correct solution (from NVIDIA-Red Hat Fabric Manager draft):** Use Fabric Manager in `FABRIC_MODE=1` (Shared NVSwitch multitenancy):
- GPUs are bound to vfio-pci at boot time (never bound to nvidia compute driver)
- Only NVSwitch devices are managed by the nvidia driver
- Fabric Manager runs in `FABRIC_MODE=1` and manages NVLink topology via the FM SDK
- GPU partitions (1, 2, 4, or 8 GPUs) are activated/deactivated via FM SDK client
- No runtime unbind/rebind needed

**Boot-time configuration required:**
1. Kernel cmdline: `vfio-pci.ids=10de:2330` to bind H100 GPUs to vfio-pci at boot
2. Install `nvidia-fabric-manager` package (must match driver version)
3. Configure FM: `FABRIC_MODE=1`, `UNIX_SOCKET_PATH=/run/nvidia-fabricmanager/fm.sock`
4. Keep at least one GPU on nvidia for NVML initialization (or modify DRA driver to skip NVML)
5. Start FM service before DRA driver

**Workaround tested:** Pre-bind GPUs to vfio-pci before starting DRA driver. VFIO prepare succeeds instantly for pre-bound GPUs (no unbind needed). VM pod starts but crashes due to virt-launcher issue (KV-5).

**DRA driver impact:** The NVIDIA DRA driver needs to detect NVSwitch systems and skip the unbind path entirely, instead using the FM SDK for GPU partition management.

**GPU Operator support:** Draft proposal exists for `ClusterPolicy.FabricManager.Mode: shared-nvswitch` — not yet implemented in the GPU Operator.

Observed on XE8640 with 4x H100 SXM5, Fedora 44, nvidia driver 595.58. Not observed on R760xa with 2x A40 (discrete PCIe, no NVLink).


#### D-12: NVIDIA DRA driver CDI spec missing /dev/vfio/vfio and IOMMU group mismatch

**Repo:** `NVIDIA/k8s-dra-driver-gpu` (CDI generation)
**Fix:** `johnahull/dra-driver-nvidia-gpu` `feature/standardized-topology-attrs` commit `cb087a2`
**Files:** `cmd/gpu-kubelet-plugin/vfio-cdi.go`
**Status:** Fixed.

When the NVIDIA DRA driver prepares a GPU that's already on vfio-pci (no unbind needed), the CDI spec may reference the wrong IOMMU group or miss `/dev/vfio/vfio`. Libvirt inside the virt-launcher then reports "VFIO PCI device assignment is not supported by the host."

**Fix:** Always include `/dev/vfio/vfio` in `GetCommonEdits()` (was gated behind `enableAPIDevice`). In `GetDeviceSpecsByPCIBusID()`, read the IOMMU group directly from sysfs (`/sys/bus/pci/devices/<BDF>/iommu_group` symlink) instead of using `nvpci.GetGPUByPciBusID()` which doesn't work for vfio-pci-bound GPUs.

---

#### D-13: NVIDIA DRA driver advertises driverless/nvidia-bound GPUs as VFIO devices

**Repo:** `NVIDIA/k8s-dra-driver-gpu` (VFIO discovery)
**Fix:** `johnahull/dra-driver-nvidia-gpu` `feature/standardized-topology-attrs` commit `e589e5a`
**Files:** `cmd/gpu-kubelet-plugin/nvlib.go`
**Status:** Fixed.

`enumerateGpuVfioDevices()` treated any NVIDIA GPU not on the nvidia driver as a VFIO candidate. This caused driverless GPUs (stuck after a failed unbind on H100 SXM5) and nvidia-bound GPUs to be advertised in the ResourceSlice as allocatable VFIO devices. When the scheduler picked one, the prepare would fail or hang trying to unbind from nvidia (D-11).

**Fix:** Check the actual kernel driver binding via sysfs (`readlink /sys/bus/pci/devices/<BDF>/driver`) before adding a GPU to the VFIO device list. Only GPUs currently bound to `vfio-pci` are advertised. This prevents the D-11 hang from recurring — even if `Unconfigure` returns a GPU to nvidia, it won't reappear as a VFIO device.


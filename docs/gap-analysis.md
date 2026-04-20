# DRA Topology Gap Analysis

**Date:** 2026-04-16

> **TL;DR:** 8 specific gaps preventing cross-driver NUMA alignment in DRA today. Each driver publishes NUMA under a different attribute name, `matchAttribute` can't span drivers, and CPU/memory have no `pcieRoot`.

Detailed technical analysis of DRA's topology gaps and driver capabilities for cross-driver NUMA-aware device co-placement.

See also: [Topology Attribute Debate](topology-attribute-debate.md) for the upstream discussion on numaNode vs pcieRoot standardization.

---

## Standardized Attributes Today (KEP-4381)

Only two standard attributes are currently defined in the upstream `k8s.io/dynamic-resource-allocation/deviceattribute` library:

| Standard Attribute | Format | Purpose |
|---|---|---|
| `resource.kubernetes.io/pcieRoot` | `pci<domain>:<bus>` (e.g., `pci0002:00`) | Identifies the PCIe Root Complex a device is behind |
| `resource.kubernetes.io/pciBusID` | `<domain>:<bus>:<device>.<function>` (e.g., `0000:87:00.0`) | PCI BDF address |

Both are in the shared library at `k8s.io/dynamic-resource-allocation/deviceattribute/`. The library provides `GetPCIeRootAttributeByPCIBusID()` which reads sysfs symlinks (`/sys/bus/pci/devices/<BDF>` -> `/sys/devices/pci<domain>:<bus>/...`) to resolve the root complex. Both the AMD and NVIDIA DRA drivers use this identical function.

> **Important:** DRA drivers that expose PCI devices MUST publish the PCI address as `resource.kubernetes.io/pciBusID` in their ResourceSlice attributes — the Kubernetes-standard attribute name — not a vendor-specific name. This is required for KEP-5304 metadata file generation and for KubeVirt to discover device BDFs for passthrough. Drivers that use vendor-specific attribute names (e.g., `pciAddr`) will not work with downstream consumers that rely on the standard name.

---

## What's NOT Standardized Yet

`numaNode` is driver-specific -- there is no `resource.kubernetes.io/numaNode` standard attribute today. Drivers expose it with different names:

| Driver | NUMA Attribute Name | Namespace |
|---|---|---|
| AMD GPU DRA Driver | `numaNode` | `gpu.amd.com/numaNode` |
| NVIDIA GPU DRA Driver | `numa` | `gpu.nvidia.com/numa` (VFIO type only) |
| CPU DRA Driver | `numaNodeID` | `dra.cpu/numaNodeID` |
| Memory DRA Driver | `numaNode` | `dra.memory/numaNode` |

This means you cannot write a cross-driver topology constraint like `matchAttribute: resource.kubernetes.io/numaNode` to co-locate an AMD GPU and a CPU on the same NUMA node. Each driver uses its own namespace.

KEP-5491 (List Types for Attributes) shipped as **alpha in v1.36** (feature gate `DRAListTypeAttributes`, default off). It uses `resource.kubernetes.io/numaNode` as a motivating example in the KEP text, but the attribute was **not formally added** to the upstream `deviceattribute` library.

For the full upstream debate, see [Topology Attribute Debate](topology-attribute-debate.md).

---

## What Each Driver Advertises for Topology

| Driver | NUMA Attribute | `resource.kubernetes.io/pciBusID` | PCIe Root | Other Topology |
|--------|---------------|----------------------------------|-----------|----------------|
| **CPU** (`dra-driver-cpu`) | `dra.cpu/numaNodeID` + `dra.net/numaNode` | N/A | No | Socket ID, L3 cache ID |
| **Memory** (`dra-driver-memory`) | `dra.memory/numaNode` + `dra.cpu/numaNodeID` + `dra.net/numaNode` | N/A | No | Page size |
| **SR-IOV** (`dra-driver-sriov`) | `dra.net/numaNode` | **Yes** | Yes | — |
| **AMD GPU** (`amd/k8s-gpu-dra-driver`) | `gpu.amd.com/numaNode` | **No** — uses vendor-specific `pciAddr` | Yes (`resource.kubernetes.io/pcieRoot`) | — |
| **NVIDIA GPU** (`nvidia/k8s-dra-driver-gpu`) | **Only for VFIO/passthrough** (not standard GPUs) | **Yes** (VFIO mode only) | Yes (`resource.kubernetes.io/pcieRoot`) | NVLink via ComputeDomains |

---

## NVIDIA vs AMD DRA Driver Comparison

### Device Types Supported

| | NVIDIA (`gpu.nvidia.com`) | AMD (`gpu.amd.com`) |
|---|---|---|
| Full GPU | `type: gpu` | `type: amdgpu` |
| Partitioned device | `type: mig` (MIG devices) | `type: amdgpu-partition` (XCP) |
| VFIO passthrough | `type: vfio` | Not supported |
| Compute Domain | channels + daemons | Not supported |

### Topology-Related Attributes per Full GPU

| Attribute | NVIDIA | AMD |
|---|---|---|
| `resource.kubernetes.io/pcieRoot` | Yes (from upstream lib) | Yes (from upstream lib) |
| `resource.kubernetes.io/pciBusID` | Yes | Yes (as driver-scoped `pciAddr`) |
| NUMA node | No (only on VFIO type, as `numa`) | Yes (`numaNode`, all device types) |
| `partitionProfile` | N/A | Yes (e.g., `cpx_nps4`) |
| `cardIndex` / `renderIndex` | No | Yes |

### NVIDIA-Specific Attributes (no AMD equivalent)

| Attribute | Type | Notes |
|---|---|---|
| `uuid` | string | GPU UUID |
| `brand` | string | e.g., "NVIDIA" |
| `architecture` | string | e.g., "Hopper" |
| `cudaComputeCapability` | semver | e.g., "9.0.0" |
| `cudaDriverVersion` | semver | CUDA driver version |
| `addressingMode` | string | Optional |

### AMD-Specific Attributes (no NVIDIA equivalent)

| Attribute | Type | Notes |
|---|---|---|
| `family` | string | GPU family string |
| `deviceID` | string | PCI device identifier |
| `driverSrcVersion` | string | Kernel driver source hash |
| `partitionProfile` | string | Compute+memory profile (e.g., `spx_nps1`) |
| `cardIndex` | int | DRM card index |
| `renderIndex` | int | DRM render node index |

### Capacities Compared

| Capacity | NVIDIA | AMD |
|---|---|---|
| `memory` | Yes (bytes) | Yes (bytes) |
| `computeUnits` | No | Yes |
| `simdUnits` | No | Yes |
| `multiprocessors` | Yes (MIG only) | No |
| `copyEngines` | Yes (MIG only) | No |
| `decoders` / `encoders` | Yes (MIG only) | No |
| `memorySlice<N>` | Yes (MIG, per-slice placement) | No |

---

## CRDs / Config API Objects

### NVIDIA -- `resource.nvidia.com/v1beta1` -- 7 API Types

| Kind | Purpose | True CRD? |
|---|---|---|
| `GpuConfig` | GPU sharing config (time-slicing, MPS) | No (opaque config in ResourceClaim) |
| `MigDeviceConfig` | MIG device sharing config | No (opaque config) |
| `VfioDeviceConfig` | VFIO passthrough config | No (opaque config) |
| `ComputeDomainChannelConfig` | IMEX channel config | No (opaque config) |
| `ComputeDomainDaemonConfig` | IMEX daemon config | No (opaque config) |
| `ComputeDomain` | Multi-node GPU memory sharing (IMEX) | **Yes** (namespaced, spec/status) |
| `ComputeDomainClique` | NVLink partition grouping | **Yes** |

NVIDIA sharing strategies:
- **Time-Slicing** -- Default, Short, Medium, Long intervals
- **MPS** (Multi-Process Service) -- configurable thread percentage, per-device pinned memory limits
- Feature-gated: `TimeSlicingSettings`, `MPSSupport`, `PassthroughSupport`

### AMD -- `gpu.resource.amd.com/v1alpha1` -- 1 API Type

| Kind | Purpose | True CRD? |
|---|---|---|
| `GpuConfig` | Placeholder -- "No configs are supported yet" | No (empty struct) |

AMD's `GpuConfig` is a stub with no fields. No sharing strategies, no VFIO config, no compute domain CRDs.

---

## The Cross-Driver Compatibility Pattern

The most important thing about the CPU, memory, and network drivers is the **compatibility attributes**:

| Driver | Its own attribute | Also publishes |
|---|---|---|
| CPU | `dra.cpu/numaNodeID` | `dra.net/numaNode` |
| Memory | `dra.memory/numaNode` | `dra.cpu/numaNodeID`, `dra.net/numaNode` |

All publish the same NUMA node value under `dra.net/numaNode`. This is an intentional design choice by the driver authors — the CPU and DraNet (SR-IOV) drivers were specifically built with provisions to work together via this shared attribute. It doesn't enable cross-ResourceClaim constraints directly, but it establishes a convention that a pod consuming multiple claims can use CEL selectors with hard-coded NUMA node values to manually align them:

```yaml
# CPU claim: pin to NUMA 0
selectors:
  - cel:
      expression: 'device.attributes["dra.cpu"].numaNodeID == 0'

# Memory claim: also pin to NUMA 0
selectors:
  - cel:
      expression: 'device.attributes["dra.memory"].numaNode == 0'
```

This is a workaround, not a real cross-claim constraint. You're hard-coding the NUMA node, which defeats scheduler flexibility.

---

## DRA Framework: MatchAttribute Constraint

The structured allocator in `dynamic-resource-allocation` has a built-in `MatchAttribute` constraint (stable channel) that ensures all devices allocated for a claim share the same value for a given attribute. This is generic — it works with any attribute name, including NUMA.

Example from the allocator test suite:

```go
intAttribute := resourceapi.FullyQualifiedName(driverA + "/" + "numa")

claimWithRequests(
    claim0,
    []resourceapi.DeviceConstraint{
        {MatchAttribute: &intAttribute},  // All devices must have same NUMA value
    },
    request(req0, classA, 1),
    request(req1, classA, 1),
)
```

Additional constraint types:
- **DistinctAttribute** (incubating/experimental) — ensures all devices have *different* values for an attribute
- **CEL selectors** — filter devices by attribute expressions (e.g., `device.attributes["dra.cpu/numaNodeID"].intValue == 0`)

### Practical Implications

**Works Today (within a single driver):**

```yaml
# AMD example: two GPUs on the same NUMA node
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
spec:
  devices:
    constraints:
    - matchAttribute: gpu.amd.com/numaNode
    requests:
    - name: gpu1
      deviceClassName: gpu.amd.com
    - name: gpu2
      deviceClassName: gpu.amd.com
```

Other within-driver examples:
- `matchAttribute: gpu.amd.com/numaNode` -- co-locate AMD GPUs on same NUMA node
- `matchAttribute: gpu.amd.com/deviceID` -- co-locate AMD GPU partitions on same physical GPU
- `matchAttribute: resource.kubernetes.io/pcieRoot` -- co-locate PCI devices under same root complex

AMD ships working examples: `example-numa-aligned-gpus.yaml`, `example-two-gpus-same-pcieroot.yaml`

**Does NOT Work Today (cross-driver):**

Cross-driver NUMA alignment requires hardcoding the NUMA node ID via CEL selectors:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
spec:
  devices:
    requests:
    - name: cpus
      deviceClassName: dra.cpu
      selectors:
      - cel:
          expression: 'device.attributes["dra.cpu/numaNodeID"].intValue == 0'
    - name: memory
      deviceClassName: dra.memory
      selectors:
      - cel:
          expression: 'device.attributes["dra.cpu/numaNodeID"].intValue == 0'
    - name: nic
      deviceClassName: sriovnetwork
      selectors:
      - cel:
          expression: 'device.attributes["dra.net/numaNode"].intValue == 0'
    - name: gpu
      deviceClassName: gpu.amd.com
      selectors:
      - cel:
          expression: 'device.attributes["gpu.amd.com/numaNode"].intValue == 0'
```

- "Give me an AMD GPU and CPUs on the same NUMA node" -- impossible without hardcoding the NUMA node ID because `gpu.amd.com/numaNode` and `dra.cpu/numaNodeID` are different attribute namespaces
- `matchAttribute` only works within a single ResourceClaim's requests (which target one driver's DeviceClass)
- DRA constraints cannot span across separate ResourceClaims

### The `pcieRoot` Attribute is the Only Truly Cross-Driver Topology Mechanism

If both NVIDIA and AMD drivers emit `resource.kubernetes.io/pcieRoot`, a constraint can theoretically co-locate devices from either driver under the same PCIe root. But in practice, a ResourceClaim targets a single `DeviceClass`, so cross-driver claims require multiple claims consumed by the same pod -- and DRA constraints can't span across separate ResourceClaims.

---

## The Fundamental Topology Gap in DRA

These drivers reveal the core limitations:

1. **No cross-claim constraints** -- DRA's `matchAttribute`/`distinctAttribute` only works within a single ResourceClaim. A pod needing "4 CPUs + 16GiB memory + 1 GPU all on NUMA node 0" must use three separate ResourceClaims (one per driver), and there's no way to constrain them to the same NUMA node without hard-coding the NUMA ID.

2. **The compatibility attributes are a social contract, not an API** -- `dra.cpu/numaNodeID`, `dra.memory/numaNode`, and `dra.net/numaNode` all carry the same value, but the drivers chose different attribute names in different namespaces. The `dra.net/numaNode` convention is an intentional coordination point between driver authors (confirmed by the CPU and DraNet driver maintainers), but it has no upstream standard backing.

3. **The real fix requires KEP-level work** -- either cross-claim constraints in the scheduler, or a standardized `resource.kubernetes.io/numaNode` attribute with scheduler awareness. KEP-5491 shipped the list-type mechanism (alpha in v1.36) but does not solve cross-claim alignment or define `numaNode` as a standard attribute.

4. **The CPU driver is the most topology-rich DRA driver that exists** -- it exposes socket, NUMA, L3 cache, core type, and SMT in a way that none of the GPU drivers do. The GPU drivers only expose NUMA and PCIe root.

### Gaps

**1. NVIDIA Does Not Advertise NUMA for Standard GPUs**

The NVIDIA DRA driver only exposes NUMA node info for **VFIO/passthrough devices** — not for regular GPU or MIG allocations. The `GpuInfo` struct has no `numaNode` field. This means NUMA-aligned GPU+CPU+memory is impossible with NVIDIA unless using GPU passthrough (e.g., for KubeVirt VMs).

Standard NVIDIA GPU attributes: UUID, productName, brand, architecture, cudaComputeCapability, driverVersion, pciBusID, pcieRoot, addressingMode. No NUMA.

**2. No Automatic Cross-Driver Coordination**

The `MatchAttribute` constraint only works within a single claim's requests **from the same driver**. There is no mechanism to say "match the NUMA node across CPU, memory, GPU, and NIC drivers simultaneously" without hardcoding the node ID.

What is missing:
```yaml
# THIS DOES NOT EXIST TODAY
constraints:
- matchAttribute: "*/numaNode"   # match across ALL drivers
```

**3. Attribute Names Are Not Unified**

| Driver | NUMA Attribute Name(s) |
|--------|----------------------|
| CPU | `dra.cpu/numaNodeID`, `dra.net/numaNode` |
| Memory | `dra.memory/numaNode`, `dra.cpu/numaNodeID`, `dra.net/numaNode` |
| SR-IOV | `dra.net/numaNode` |
| AMD GPU | `gpu.amd.com/numaNode` |
| NVIDIA GPU | `numa` (VFIO only, under driver domain) |

The CPU/memory/SR-IOV drivers made a good effort with shared compatibility attributes, but the GPU drivers use their own namespaces. There is no standard like `resource.kubernetes.io/numaNode`.

**4. No Topology Distance Awareness**

You can express "same NUMA node" but not "closest NUMA node" or "within N hops." There is no concept of topology distance, preference (vs. hard requirement), or NUMA distance metrics. The kernel exposes continuous NUMA distances via ACPI SLIT (relative cost values like 10, 21, 31) and newer systems provide actual latency/bandwidth via ACPI HMAT, but DRA has no mechanism to consume either. For the co-placement use case, two discrete proximity tiers (pcieRoot for same-switch, numaNode for same-memory-controller) are sufficient — continuous distance metrics are a potential future extension.

**5. No xGMI / Infinity Fabric / NVLink Topology for Single-Node**

- AMD: No xGMI or Infinity Fabric distance metrics advertised
- NVIDIA: NVLink topology only available via ComputeDomains for multi-node MNNVL scenarios, not for intra-node GPU-to-GPU NVLink topology

---

## Capability Matrix

| Scenario | Works Today? | Notes |
|----------|-------------|-------|
| 2 AMD GPUs on same NUMA node | **Yes** | AMD driver has examples |
| 2 NVIDIA GPUs on same NUMA node | **No** | NUMA not advertised for standard GPUs |
| CPUs + memory on same NUMA node | **Yes** | Shared compatibility attributes |
| SR-IOV NIC + CPUs on same NUMA node | **Yes** | Via `dra.net/numaNode` |
| GPU + NIC + CPU + memory all on same NUMA | **AMD only** | Requires hardcoding NUMA node ID |
| Automatic best-fit NUMA node for all resources | **No** | No cross-driver MatchAttribute |
| Topology-aware VM device assignment | **No** | KubeVirt + DRA integration immature |
| GPU-to-GPU interconnect topology (NVLink/xGMI) | **Partial** | NVIDIA ComputeDomains for multi-node only |
| NUMA distance / preference (soft affinity) | **No** | Only hard constraints supported |

---

## What Would Be Needed

1. **All PCI DRA drivers must publish `resource.kubernetes.io/pciBusID`** — This is the Kubernetes-standard ResourceSlice attribute for PCI device identity (defined in KEP-4381, implemented in the upstream `deviceattribute` library). It is required for KEP-5304 metadata file generation and for KubeVirt device discovery. Drivers that publish BDF under vendor-specific attribute names (e.g., AMD's `pciAddr`) must switch to the standard name. Without this, the kubelet will not include the BDF in KEP-5304 metadata files and downstream consumers (KubeVirt, device monitoring, etc.) cannot discover allocated devices.
2. **Unified NUMA attribute** — A standard attribute like `resource.kubernetes.io/numaNode` that all drivers adopt (same pattern as `resource.kubernetes.io/pciBusID` for PCI addresses). KEP-5491 (alpha in v1.36) provides the list-type mechanism and uses this name as a motivating example, but the attribute itself was not formally added to the upstream `deviceattribute` library. Defining and standardizing it remains a separate effort.
3. **Cross-driver MatchAttribute** — Scheduler support for matching attributes across different driver domains within a single ResourceClaim
4. **NVIDIA NUMA for standard GPUs** — The NVIDIA DRA driver should expose `numaNode` for all device types, not just VFIO
5. **Topology distance / soft affinity** — A preference-based constraint ("prefer same NUMA, but don't fail") alongside the existing hard `MatchAttribute`
6. **KubeVirt DRA integration** — Mature support for passing DRA-allocated devices (with topology awareness) into VMs

---

## Key Architectural Differences

- **NVIDIA has VFIO as a first-class DRA device type** -- bridging the DRA-to-KubeVirt gap within a single driver. AMD keeps VFIO on the Device Plugin path.
- **NVIDIA's ComputeDomain CRD is novel** -- it orchestrates IMEX daemons across nodes for multi-node GPU memory sharing (NVLink domains). No AMD equivalent exists.
- **AMD's strength is hardware-level partitioning** -- XCP partitions are firmware-level splits with dedicated CUs and VRAM, not time-shared. NVIDIA MIG is conceptually similar but NVIDIA creates/destroys MIG devices dynamically via NVML, while AMD reads pre-partitioned devices from sysfs (partitioning is done externally by DCM).

---

## Key Source Files

### DRA Framework
- `dynamic-resource-allocation/structured/internal/stable/allocator_stable.go` — MatchAttribute constraint implementation (lines 641-756)
- `dynamic-resource-allocation/structured/internal/allocatortesting/allocator_testing.go` — NUMA test cases (lines 1880-1970, 5495-5542, 5870-5969)

### CPU/Memory/SR-IOV Drivers
- `dra-driver-cpu/pkg/device/attributes.go` — `SetCompatibilityAttributes()` sets `dra.net/numaNode`
- `dra-driver-memory/pkg/sysinfo/rslice.go` — `MakeAttributes()` creates NUMA compatibility attributes (lines 34-50)
- `dra-driver-sriov/pkg/devicestate/discovery.go` — NUMA node discovery via `GetNumaNode()` (lines 78-84)

### AMD GPU DRA Driver
- `amd/k8s-gpu-dra-driver/pkg/amd/discovery.go` — NUMA node read from sysfs (lines 142-171)
- `amd/k8s-gpu-dra-driver/docs/driver-attributes.md` — Topology attribute documentation (lines 155-210)
- `amd/k8s-gpu-dra-driver/example/example-numa-aligned-gpus.yaml`
- `amd/k8s-gpu-dra-driver/example/example-two-gpus-same-pcieroot.yaml`

### NVIDIA GPU DRA Driver
- `nvidia/k8s-dra-driver-gpu/cmd/gpu-kubelet-plugin/deviceinfo.go` — VFIO NUMA attribute (lines 261-263), standard GPU attributes (lines 159-203)
- `nvidia/k8s-dra-driver-gpu/api/nvidia.com/resource/v1beta1/computedomain.go` — NVLink ComputeDomain topology

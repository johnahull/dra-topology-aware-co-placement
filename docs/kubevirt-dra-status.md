# KubeVirt DRA Support Status

**Date:** 2026-05-04

## Upstream (kubevirt/kubevirt main)

GPU and NIC passthrough via DRA is implemented upstream as VEP-10. Both are alpha features.

### Feature Gates

| Gate | Status | Purpose |
|------|--------|---------|
| `DRA` | Alpha | Enable DRA resource claims in VMI specs |
| `GPUsWithDRA` | Alpha | GPU passthrough via DRA claims |
| `HostDevicesWithDRA` | Alpha | Host device (NIC, NVMe, etc.) passthrough via DRA claims |
| `CPUManager` | Alpha | Dedicated CPU placement |
| `ReservedOverheadMemlock` | Alpha | `reservedOverhead.addedOverhead` for VFIO memory locking |

### What works upstream

**GPU passthrough:**
- `ClaimRequest` field on `vmi.Spec.Domain.Devices.GPUs[]`
- Reads `pciBusID` from KEP-5304 metadata → PCI hostdev in domain XML
- Reads `mdevUUID` from KEP-5304 metadata → mediated device (vGPU)
- `WithGPUsDRA` adds claim references to pod spec
- Validation via DRA admitter

**Host device passthrough (NICs, NVMe, etc.):**
- `ClaimRequest` field on `vmi.Spec.Domain.Devices.HostDevices[]`
- Same KEP-5304 metadata lookup as GPUs (`pciBusID` or `mdevUUID`)
- `WithHostDevicesDRA` adds claim references to pod spec
- `permittedHostDevices` validation skipped for DRA devices

**KEP-5304 metadata reading (`pkg/dra/utils.go`):**
- `GetPCIAddressForClaim` — reads `resource.kubernetes.io/pciBusID`
- `GetMDevUUIDForClaim` — reads `mdevUUID`
- JSON stream decoder for multi-version metadata files
- Template and direct claim path resolution
- `DefaultMetadataBasePath` = `/var/run/kubernetes.io/dra-device-attributes`

**Pod rendering (`pkg/virt-controller/services/`):**
- `renderresources.go` — `WithGPUsDRA`, `WithHostDevicesDRA`, `copyResourceClaims`
- `template.go` — DRA claim forwarding in pod template

### Key upstream files

| File | Purpose |
|------|---------|
| `pkg/dra/utils.go` | KEP-5304 metadata reading, claim resolution |
| `pkg/dra/metadata/` | Metadata types (`DeviceMetadata`, `Device`, `Request`) |
| `pkg/dra/admitter/dra_admitter.go` | DRA GPU/hostDevice validation |
| `pkg/virt-launcher/virtwrap/device/hostdevice/dra/gpu_hostdev.go` | GPU hostdev creation from metadata |
| `pkg/virt-launcher/virtwrap/device/hostdevice/dra/generic_hostdev.go` | Generic hostdev creation from metadata |
| `pkg/virt-controller/services/renderresources.go` | Pod spec claim references |

## What's NOT upstream (in our fork only)

### Bugs (PRs submitted)

| Issue | PR | Description |
|-------|----|-------------|
| KV-1 | [#17673](https://github.com/kubevirt/kubevirt/pull/17673) | `copyResourceClaims` deduplicates by Name only — drops second request from same claim |
| KV-7 | [#17675](https://github.com/kubevirt/kubevirt/pull/17675) | Missing `IPC_LOCK` and `SYS_RAWIO` capabilities for DRA VFIO pods |

### Features (in fork, not submitted)

**KV-5: NUMA node from KEP-5304 metadata**
- `GetNUMANodeForClaim` — reads `numaNode` from device metadata
- Required for guest NUMA topology mapping
- Depends on U-2 (standardized `resource.kubernetes.io/numaNode`)
- File: `pkg/dra/utils.go`

**KV-9: Guest NUMA topology from DRA metadata**
- `buildDRANUMACells` — creates guest NUMA cells from KEP-5304 device NUMA
- `DiscoverNUMANodesFromAllMetadata` — scans all metadata files for NUMA info
- Replaces cpuset-based NUMA detection for `guestMappingPassthrough`
- Enables multi-NUMA VMs with DRA device placement
- Files: `pkg/virt-launcher/virtwrap/converter/converter.go`, `pkg/dra/utils.go`

**KV-10: GPU pxb-pcie placement**
- `buildDRANUMAOverrides` — builds PCI-to-NUMA mapping from GPU and hostDevice metadata
- `PlacePCIDevicesWithNUMAAlignment` — creates `pxb-pcie` expander buses per NUMA
- Places GPUs on correct guest NUMA node for topology-aware workloads
- File: `pkg/virt-launcher/virtwrap/converter/converter.go`

**KV-8: cpumanager label skip for DRA CPU claims**
- Skip `kubevirt.io/cpumanager=true` node selector when DRA CPU claims present
- Required for Option A (`cpuManagerPolicy: none`) with DRA CPU driver
- Files: `pkg/virt-handler/heartbeat/heartbeat.go`, `pkg/virt-controller/services/nodeselectorrenderer.go`

**Template claim metadata lookup fix**
- `findMetadataByPodClaimName` — searches by `PodClaimName` for template-generated claims
- Upstream only handles direct claims by exact path; templates need glob + match
- File: `pkg/dra/utils.go`

## DRA driver requirements for KubeVirt

For a DRA driver to work with KubeVirt VM passthrough:

| Requirement | Purpose | Drivers that have it |
|-------------|---------|---------------------|
| VFIO bind/unbind | Bind device to vfio-pci for guest access | NVIDIA GPU (upstream), SR-IOV (upstream), dranet (fork) |
| KEP-5304 `pciBusID` | Virt-launcher reads PCI address for hostdev XML | NVIDIA GPU (upstream), NVMe (fork), dranet (fork) |
| KEP-5304 `mdevUUID` | Virt-launcher reads mdev UUID for vGPU | NVIDIA GPU (upstream) |
| CDI spec for `/dev/vfio/*` | Container needs VFIO device nodes | NVIDIA GPU (upstream), SR-IOV (upstream), dranet (fork) |
| `resource.kubernetes.io/numaNode` | Guest NUMA topology (KV-5/9) | All drivers (fork only, depends on U-2) |

### Driver status for KubeVirt

| Driver | VFIO | KEP-5304 | NUMA attrs | KubeVirt ready? |
|--------|------|----------|------------|-----------------|
| NVIDIA GPU (`gpu.nvidia.com`) | Upstream | Upstream (alpha gate) | Fork | Yes (upstream) |
| SR-IOV NIC (`k8snetworkplumbingwg`) | Upstream | Fork (`fix/kep5304-metadata`) | Fork | Needs KEP-5304 PR |
| dranet (`dra.net`) | Fork | Fork | Fork | Fork only |
| NVMe (`dra.nvme`) | Fork | Fork | Fork | Fork only |
| CPU (`dra.cpu`) | N/A | No | Fork | N/A (not passthrough) |
| Memory (`dra.memory`) | N/A | No | Fork | N/A (topology marker) |

## Fork branches

| Branch | Base | Contents |
|--------|------|----------|
| `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.2` | v1.8.2 | KV-1, KV-5, KV-7, KV-8, KV-9, KV-10 + VFIO capabilities |
| `johnahull/kubevirt` `fix/dra-claim-dedup` | main | KV-1 only (upstream PR) |
| `johnahull/kubevirt` `fix/dra-vfio-capabilities` | main | KV-7 only (upstream PR) |

## Tested configurations

| System | GPUs | NICs | Result |
|--------|------|------|--------|
| Dell XE8640 | 3x H100 SXM5 VFIO | Mellanox CX6 Dx VFIO | 5-driver VM, multi-NUMA guest topology, pxb-pcie placement |
| Dell R760xa | 2x A40 VFIO | ConnectX-7 VFs | Multi-claim NUMA alignment, per-CPU individual mode |

## What needs to happen for full upstream support

1. **U-2** — Standardize `resource.kubernetes.io/numaNode` (sig-node meeting)
2. **KV-1** — Merge claim dedup fix ([PR #17673](https://github.com/kubevirt/kubevirt/pull/17673))
3. **KV-7** — Merge VFIO capabilities fix ([PR #17675](https://github.com/kubevirt/kubevirt/pull/17675))
4. **KV-5/9/10** — Submit guest NUMA topology from KEP-5304 (after U-2)
5. **SR-IOV driver** — Merge KEP-5304 metadata (`fix/kep5304-metadata` branch)

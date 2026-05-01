# XE8640 Multi-NUMA VM Test Results

**Date:** 2026-05-01
**System:** Dell XE8640, 4x NVIDIA H100 SXM5 80GB (NVLink), ConnectX-6 Dx + E810 NICs, 128 CPUs, 1 TiB RAM
**OS:** Fedora 44, kernel 6.19.14, nvidia driver 595.58
**K8s:** Custom v1.36.0 (`feature/dra-topology-hints-v1.36`)
**KubeVirt:** v1.8.2 with custom virt-controller + virt-launcher (`feature/dra-vfio-numa-passthrough-v1.8.2`)
**CPU policy:** Option A — `cpuManagerPolicy: none`, DRA CPU driver (`--cpu-device-mode=individual`) NRI pinning

## DRA Drivers Deployed

| Driver | Devices | Mode |
|--------|---------|------|
| gpu.nvidia.com | 4 (1 nvidia + 3 vfio-pci) | PassthroughSupport + DeviceMetadata |
| dra.net (dranet) | 6 NICs (2 PF + 2 VF Mellanox, 2 Intel E810) | vfioUnsafe filter enabled |
| dra.nvme | 4 NVMe (boot disk excluded) | block/vfio modes |
| dra.cpu | 128 per-CPU devices | `--cpu-device-mode=individual` |
| dra.memory | 4 devices (2 regular + 2 hugepages) | topology marker only |

## VM Claim

3x H100 GPUs (2 NUMA 0, 1 NUMA 1) + 1 Mellanox NIC (VFIO) + 4 CPUs per NUMA + `guestMappingPassthrough`

```
dra-verify.sh claims:

default/virt-launcher-dra-topology-vm-f9c57-devices-5ktdl  →  VM default/dra-topology-vm
  requests: cpus-numa0: 4x cpu, cpus-numa1: 4x cpu
  Request     Driver                   Device              NUMA  pcieRoot        PCI Bus ID
  ─────────────────────────────────────────────────────────────────────────────────────────
  gpu0        gpu.nvidia.com           gpu-vfio-0          0     pci0000:48      0000:4e:00.0
  gpu1        gpu.nvidia.com           gpu-vfio-1          0     pci0000:59      0000:5f:00.0
  gpu2        gpu.nvidia.com           gpu-vfio-3          1     pci0000:d7      0000:db:00.0
  nic0        dra.net                  pci-0000-27-00-0    0     pci0000:26      0000:27:00.0
  cpus-numa0  dra.cpu                  cpudev000           0
  cpus-numa0  dra.cpu                  cpudev001           0
  cpus-numa0  dra.cpu                  cpudev004           0
  cpus-numa0  dra.cpu                  cpudev005           0
  cpus-numa1  dra.cpu                  cpudev002           1
  cpus-numa1  dra.cpu                  cpudev003           1
  cpus-numa1  dra.cpu                  cpudev006           1
  cpus-numa1  dra.cpu                  cpudev007           1

  ! Multi-NUMA: devices on NUMA 0, 1
```

## Guest NUMA Topology (domain XML)

```xml
<numatune>
  <memory mode='strict' nodeset='0-1'/>
  <memnode cellid='0' mode='strict' nodeset='0'/>
  <memnode cellid='1' mode='strict' nodeset='1'/>
</numatune>

<numa>
  <cell id='0' cpus='0-3,8-31' memory='4194304' unit='KiB'/>
  <cell id='1' cpus='4-7' memory='4194304' unit='KiB'/>
</numa>
```

## pxb-pcie Expander Buses

```xml
<!-- NUMA 0 -->
<controller type='pci' index='1' model='pcie-expander-bus'>
  <model name='pxb-pcie'/>
  <target busNr='252'><node>0</node></target>
</controller>

<!-- NUMA 1 -->
<controller type='pci' index='5' model='pcie-expander-bus'>
  <model name='pxb-pcie'/>
  <target busNr='250'><node>1</node></target>
</controller>
```

## VFIO Hostdev Entries

| Device | Host PCI | Guest PCI | pxb-pcie NUMA |
|--------|----------|-----------|---------------|
| gpu0 (H100 SXM5) | 0000:4e:00.0 | 0000:02:00.0 | NUMA 0 |
| gpu1 (H100 SXM5) | 0000:5f:00.0 | 0000:03:00.0 | NUMA 0 |
| gpu2 (H100 SXM5) | 0000:db:00.0 | 0000:06:00.0 | NUMA 1 |
| nic0 (ConnectX-6 Dx) | 0000:27:00.0 | 0000:04:00.0 | NUMA 0 |

## Guest Verification

- Guest NUMA node 0: CPUs 0-3
- Guest NUMA node 1: CPUs 4-7
- GPUs visible as NVIDIA vendor (0x10de) device 0x2330 (H100 SXM5)
- GPUs report correct `numa_node` matching their pxb-pcie placement

## Key Fixes Applied

- D-13: VFIO discovery filter (only vfio-pci GPUs advertised)
- D-14: Unconfigure skip for pre-bound GPUs (vfio-pci.ids)
- D-15: sysfs container path fallback
- D-16: dranet vfioUnsafe filter (shared IOMMU group detection)
- D-17: NVMe boot disk exclusion (/proc/1/mounts)
- KV-9: buildDRANUMACells from KEP-5304 metadata
- KV-10: GPU pxb-pcie placement via buildDRANUMAOverrides
- DRA CPU individual mode: per-CPU devices with count: N

# Spec: DRA Driver for NVMe Devices

## Goal

A DRA driver that discovers local NVMe devices and publishes them as allocatable resources with topology attributes. This enables NVMe drives to participate in cross-driver NUMA co-placement alongside GPUs, NICs, CPUs, and memory — ensuring that workloads needing local storage get an NVMe on the same NUMA node as their other devices.

## Why

Today, NVMe devices are consumed via PersistentVolumes and CSI drivers with no NUMA awareness. The storage scheduler picks a volume based on capacity, not topology. A workload can get a GPU on NUMA 0 and an NVMe on NUMA 1, causing every data load to cross the NUMA boundary.

Use cases where NVMe NUMA alignment matters:
- **AI training dataset loading** — streaming training data from local NVMe into GPU memory; the path is NVMe → CPU → GPU, all of which should be NUMA-local
- **Model checkpoint writing** — large checkpoints (tens of GB) written during training
- **KV cache offloading** — inference workloads (e.g., vLLM) spilling KV cache from GPU memory to local NVMe
- **KubeVirt VM passthrough** — passing NVMe devices to VMs via VFIO with correct guest NUMA topology

## Device Discovery

### Sysfs Paths

```
/sys/class/nvme/nvme*/                     # NVMe controllers
/sys/class/nvme/nvme*/device/              # PCI device symlink
/sys/class/nvme/nvme*/device/numa_node     # NUMA node
/sys/block/nvme*n*/                        # NVMe namespaces (block devices)
/sys/block/nvme*n*/size                    # Size in 512-byte sectors
/sys/block/nvme*n*/queue/rotational        # Always 0 for NVMe
```

### Information to Collect

Per NVMe controller:
- **PCI address** — from `/sys/class/nvme/nvme*/device` symlink (e.g., `0000:3b:00.0`)
- **NUMA node** — from `/sys/class/nvme/nvme*/device/numa_node`
- **Model** — from `/sys/class/nvme/nvme*/model`
- **Serial** — from `/sys/class/nvme/nvme*/serial`
- **Firmware** — from `/sys/class/nvme/nvme*/firmware_rev`

Per NVMe namespace:
- **Size** — from `/sys/block/nvme*n*/size` (sectors × 512 = bytes)
- **Block device path** — `/dev/nvme0n1`, `/dev/nvme1n1`, etc.

### Device Naming

Follow the `<type>-<index>` pattern used by other drivers:
- `nvme-0`, `nvme-1`, etc. for full controllers
- `nvme-0-ns1`, `nvme-0-ns2` for individual namespaces (if exposing per-namespace)

Most systems have one namespace per controller, so the controller-level device is sufficient.

## ResourceSlice Attributes

### Standard Attributes (from `deviceattribute` library)

| Attribute | Source | Example |
|-----------|--------|---------|
| `resource.kubernetes.io/pciBusID` | `GetPCIBusIDAttribute(pciAddr)` | `0000:3b:00.0` |
| `resource.kubernetes.io/pcieRoot` | `GetPCIeRootAttributeByPCIBusID(pciAddr)` | `pci0000:3a` |
| `resource.kubernetes.io/numaNode` | sysfs `numa_node` | `0` |
| `resource.kubernetes.io/cpuSocketID` | derived from NUMA-to-socket mapping | `0` |

### Driver-Specific Attributes

| Attribute | Type | Example |
|-----------|------|---------|
| `dra.nvme/model` | string | `Samsung_SSD_990_PRO_2TB` |
| `dra.nvme/serial` | string | `S6Z2NF0W123456` |
| `dra.nvme/firmwareRev` | string | `4B2QJXE7` |
| `dra.nvme/transport` | string | `pcie` |

### Capacity

| Capacity Key | Type | Example |
|-------------|------|---------|
| `dra.nvme/size` | quantity | `2Ti` |

### Example ResourceSlice Device

```yaml
- name: nvme-0
  attributes:
    resource.kubernetes.io/pciBusID:
      stringValue: "0000:3b:00.0"
    resource.kubernetes.io/pcieRoot:
      stringValue: "pci0000:3a"
    resource.kubernetes.io/numaNode:
      intValue: 0
    resource.kubernetes.io/cpuSocketID:
      intValue: 0
    dra.nvme/model:
      stringValue: "Samsung_SSD_990_PRO_2TB"
    dra.nvme/serial:
      stringValue: "S6Z2NF0W123456"
    dra.nvme/transport:
      stringValue: "pcie"
  capacity:
    dra.nvme/size:
      value: "2Ti"
```

## DeviceClass Examples

```yaml
# All NVMe devices
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.nvme
spec:
  selectors:
  - cel:
      expression: "device.driver == \"dra.nvme\""
---
# NVMe devices on NUMA 0 only
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.nvme-numa0
spec:
  selectors:
  - cel:
      expression: "device.driver == \"dra.nvme\""
  - cel:
      expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 0"
---
# NVMe for VFIO passthrough to VMs
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.nvme-vfio
spec:
  selectors:
  - cel:
      expression: "device.driver == \"dra.nvme\""
  config:
  - opaque:
      driver: dra.nvme
      parameters:
        apiVersion: nvme.resource.k8s.io/v1alpha1
        kind: NvmeConfig
        mode: vfio
```

## Cross-Driver Topology Alignment

With standardized `resource.kubernetes.io/numaNode`, a single claim can co-locate GPU + NIC + NVMe + CPU + memory:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.nvidia.com
        count: 1
    - name: nic
      exactly:
        deviceClassName: sriovnetwork
        count: 1
    - name: nvme
      exactly:
        deviceClassName: dra.nvme
        count: 1
    - name: cpu
      exactly:
        deviceClassName: dra.cpu
        count: 1
    constraints:
    - matchAttribute: resource.kubernetes.io/numaNode
      requests: [gpu, nic, nvme, cpu]
```

## Prepare / Unprepare Flow

### Block Device Mode (pods)

```
Prepare:
  1. Look up allocated NVMe device in allocatable map
  2. Generate CDI spec with block device paths:
     - /dev/nvme0n1 (block device)
     - /dev/nvme0 (controller character device)
  3. Optionally create a filesystem (mkfs) if requested via config
  4. Publish KEP-5304 metadata (pciBusID, numaNode, model)
  5. Checkpoint allocation state

Unprepare:
  1. Remove CDI spec
  2. Clean checkpoint
  (Block device is not wiped — that's a policy decision)
```

### VFIO Mode (VMs)

```
Prepare:
  1. Unbind NVMe from nvme kernel driver
  2. Bind to vfio-pci via driver_override
  3. Read IOMMU group from sysfs
  4. Generate CDI spec with /dev/vfio/* devices
  5. Publish KEP-5304 metadata (pciBusID, numaNode)
  6. Checkpoint allocation state

Unprepare:
  1. Unbind from vfio-pci
  2. Rebind to nvme kernel driver
  3. Remove CDI spec
  4. Clean checkpoint
```

## CDI Spec Generation

### Block Device Mode

```json
{
  "kind": "dra.nvme/nvme",
  "devices": [{
    "name": "<claimUID>-nvme-0",
    "containerEdits": {
      "deviceNodes": [
        {"path": "/dev/nvme0n1", "hostPath": "/dev/nvme0n1", "type": "b"},
        {"path": "/dev/nvme0", "hostPath": "/dev/nvme0", "type": "c"}
      ]
    }
  }]
}
```

### VFIO Mode

```json
{
  "kind": "dra.nvme/nvme",
  "devices": [{
    "name": "<claimUID>-nvme-0",
    "containerEdits": {
      "deviceNodes": [
        {"path": "/dev/vfio/vfio", "hostPath": "/dev/vfio/vfio", "type": "c"},
        {"path": "/dev/vfio/42", "hostPath": "/dev/vfio/42", "type": "c"}
      ]
    }
  }]
}
```

## KEP-5304 Metadata

```go
dev.Metadata = &kubeletplugin.DeviceMetadata{
    Attributes: map[string]resourceapi.DeviceAttribute{
        "resource.kubernetes.io/pciBusID": {StringValue: &pciAddr},
        "numaNode":                        {IntValue: &numaNode},
        "model":                           {StringValue: &model},
    },
}
```

This enables KubeVirt virt-launcher to:
1. Read `pciBusID` → create `<hostdev>` entry for VFIO passthrough
2. Read `numaNode` → place on correct guest NUMA node via VEP 115 pxb-pcie

## Config API

```go
type NvmeConfig struct {
    metav1.TypeMeta `json:",inline"`
    // Mode selects the device exposure mode.
    // "block" (default) exposes /dev/nvme*n* block devices.
    // "vfio" binds to vfio-pci for VM passthrough.
    Mode string `json:"mode,omitempty"`
}
```

## KubeVirt Integration

NVMe VFIO passthrough to VMs follows the same pattern as GPU and NIC:

1. DRA allocates NVMe with `matchAttribute: numaNode` alongside GPU + NIC
2. Driver binds NVMe to vfio-pci, publishes KEP-5304 metadata
3. KubeVirt virt-launcher reads pciBusID from metadata
4. Creates `<hostdev>` entry in domain XML
5. VEP 115 reads numaNode from metadata, places on correct guest pxb-pcie bus
6. Guest sees NVMe on the same NUMA node as GPU and NIC

No changes needed to KubeVirt — the existing DRA hostDevice + VEP 115 path handles any PCI VFIO device.

## What's NOT In Scope

- **Filesystem management** — the driver exposes block devices, not filesystems. Mounting and formatting is the workload's responsibility (or a CSI layer on top).
- **NVMe-oF (NVMe over Fabrics)** — this spec covers local PCIe-attached NVMe only. Network-attached NVMe is a different topology model.
- **Namespace partitioning** — NVMe namespace management (creating/deleting namespaces on a controller) is out of scope for the initial driver. Each namespace is treated as a separate device.
- **Encryption / secure erase** — device-level security features are policy, not topology.

## Implementation Structure

Following the established DRA driver pattern:

```
dra-driver-nvme/
├── cmd/nvme-kubeletplugin/
│   ├── main.go              # Entry point, flags, kubeletplugin.Start()
│   ├── driver.go            # PrepareResourceClaims / UnprepareResourceClaims
│   ├── discovery.go         # Enumerate NVMe devices from sysfs
│   ├── allocatable.go       # AllocatableDevice wrapper
│   ├── deviceinfo.go        # NvmeInfo struct, GetDevice() → ResourceSlice
│   ├── state.go             # Prepare/Unprepare state machine, VFIO bind/unbind
│   ├── cdi.go               # CDI spec generation (block + VFIO modes)
│   ├── checkpoint.go        # Allocation state persistence
│   └── types.go             # Constants
├── api/nvme.resource.k8s.io/v1alpha1/
│   └── api.go               # NvmeConfig type
├── pkg/nvme/
│   └── nvme.go              # Sysfs reading helpers
├── deploy/
│   ├── daemonset.yaml        # DaemonSet for the kubelet plugin
│   └── deviceclass.yaml      # Default DeviceClass
├── Dockerfile
├── go.mod
└── README.md
```

## Dependencies

- `k8s.io/dynamic-resource-allocation/kubeletplugin` — DRA plugin framework
- `k8s.io/dynamic-resource-allocation/deviceattribute` — standard topology attributes (pciBusID, pcieRoot)
- `tags.cncf.io/container-device-interface` — CDI spec generation
- No external hardware libraries needed — NVMe discovery is pure sysfs

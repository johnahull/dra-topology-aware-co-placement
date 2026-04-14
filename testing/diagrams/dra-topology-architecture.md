# DRA Topology-Aware Co-Placement Architecture

## Overview

DRA (Dynamic Resource Allocation) enables NUMA-aware device co-placement across multiple drivers. The topology coordinator discovers devices from all DRA drivers, creates partition DeviceClasses with NUMA alignment constraints, and a webhook expands simple partition claims into multi-driver requests.

---

## Component Architecture

```mermaid
graph TB
    subgraph "Control Plane"
        SCHED[kube-scheduler]
        API[kube-apiserver]
        COORD[Topology Coordinator]
        WEBHOOK[Partition Webhook]
    end

    subgraph "Node"
        KUBELET[kubelet]
        CRIO[CRI-O / containerd]
        NRI[NRI Socket]

        subgraph "DRA Drivers"
            CPU_DRV[DRA CPU Driver]
            SRIOV_DRV[DRA SR-IOV Driver]
            MEM_DRV[DRA Memory Driver]
        end

        subgraph "Hardware — NUMA 0"
            CPU0[64 CPUs]
            NIC0[ConnectX-6 VFs]
            GPU0[MI300X VFs]
            MEM0[Memory + Hugepages]
        end

        subgraph "Hardware — NUMA 1"
            CPU1[64 CPUs]
            NIC1[ConnectX-6 VFs]
            GPU1[MI300X VFs]
            MEM1[Memory + Hugepages]
        end
    end

    CPU_DRV -->|ResourceSlice| API
    SRIOV_DRV -->|ResourceSlice| API
    MEM_DRV -->|ResourceSlice| API

    CPU_DRV -->|discovers| CPU0
    CPU_DRV -->|discovers| CPU1
    SRIOV_DRV -->|discovers| NIC0
    SRIOV_DRV -->|discovers| NIC1
    MEM_DRV -->|discovers| MEM0
    MEM_DRV -->|discovers| MEM1

    COORD -->|reads ResourceSlices| API
    COORD -->|creates DeviceClasses| API
    WEBHOOK -->|mutates ResourceClaims| API

    SCHED -->|allocates devices| API
    KUBELET -->|PrepareResources| CPU_DRV
    KUBELET -->|PrepareResources| SRIOV_DRV
    CPU_DRV -->|NRI cpuset.cpus| NRI
    SRIOV_DRV -->|NRI metadata mount| NRI
    NRI -->|adjusts containers| CRIO
```

---

## Plain Pod Flow

How a NUMA-aligned pod gets CPU + NIC VFs from the same NUMA node.

```mermaid
sequenceDiagram
    participant User
    participant API as kube-apiserver
    participant Sched as kube-scheduler
    participant Kubelet
    participant CPU as DRA CPU Driver
    participant SRIOV as DRA SR-IOV Driver
    participant NRI as NRI (CRI-O/containerd)
    participant Pod

    User->>API: Create ResourceClaim<br/>(cpu + nic, matchAttribute: dra.net/numaNode)
    User->>API: Create Pod (references claim)

    API->>Sched: Schedule pod
    Sched->>Sched: Find node where cpu + nic<br/>share same numaNode value
    Sched->>API: Allocate devices<br/>(cpudevnuma000 + 4 NIC VFs from NUMA 0)

    Kubelet->>CPU: PrepareResources(cpudevnuma000)
    CPU->>CPU: Generate CDI spec
    CPU-->>NRI: Register NRI plugin

    Kubelet->>SRIOV: PrepareResources(4 NIC VFs)
    SRIOV->>SRIOV: Bind VFs to vfio-pci
    SRIOV->>SRIOV: Write KEP-5304 metadata JSON
    SRIOV->>SRIOV: Generate CDI spec (devices + mounts)
    SRIOV-->>NRI: Register NRI plugin

    Kubelet->>NRI: CreateContainer
    NRI->>NRI: CPU driver sets cpuset.cpus
    NRI->>NRI: SR-IOV driver injects metadata mount
    NRI->>Pod: Container starts with:<br/>• cpuset pinned to NUMA 0<br/>• /dev/vfio/* devices<br/>• KEP-5304 metadata at<br/>/var/run/dra-device-attributes/

    Note over Pod: Pod sees:<br/>64 CPUs (NUMA 0)<br/>4 VFIO NIC VFs (NUMA 0)<br/>PCI BDFs in metadata
```

---

## KubeVirt VM Flow

How a VM gets 2 guest NUMA nodes with GPU + NIC devices NUMA-aligned via VEP 115.

```mermaid
sequenceDiagram
    participant User
    participant API as kube-apiserver
    participant Sched as kube-scheduler
    participant VirtCtrl as virt-controller
    participant Kubelet
    participant SRIOV as DRA SR-IOV Driver
    participant NRI as NRI
    participant VirtLauncher as virt-launcher
    participant Libvirt
    participant VM as Guest VM

    User->>API: Create ResourceClaims<br/>(nic-numa0: CEL numaNode==0)<br/>(nic-numa1: CEL numaNode==1)
    User->>API: Create VirtualMachine<br/>(GPU VFs via device plugin +<br/>NIC VFs via DRA claims +<br/>dedicatedCpuPlacement +<br/>guestMappingPassthrough +<br/>features.acpi)

    VirtCtrl->>API: Create virt-launcher Pod<br/>(hostDevices + resourceClaims)

    API->>Sched: Schedule pod
    Sched->>API: Allocate NIC VFs per claim

    Kubelet->>SRIOV: PrepareResources
    SRIOV->>SRIOV: Bind to vfio-pci
    SRIOV->>SRIOV: Write KEP-5304 metadata

    Kubelet->>NRI: CreateContainer
    NRI->>NRI: Inject metadata mounts
    NRI->>VirtLauncher: Container starts

    VirtLauncher->>VirtLauncher: Read cpuset.cpus<br/>(needs cross-NUMA CPUs)
    VirtLauncher->>VirtLauncher: numaMapping() → 2 NUMA cells
    VirtLauncher->>VirtLauncher: Read KEP-5304 metadata<br/>→ PCI BDFs for NIC VFs
    VirtLauncher->>VirtLauncher: Read sysfs NUMA for<br/>GPU + NIC PCI devices

    Note over VirtLauncher: VEP 115: PlacePCIDevicesWithNUMAAlignment()

    VirtLauncher->>VirtLauncher: Create pxb-pcie bus per NUMA node
    VirtLauncher->>VirtLauncher: Place GPU/NIC on NUMA-correct bus

    VirtLauncher->>Libvirt: Define domain XML:<br/>• 2 NUMA cells (3 CPUs + 3 GiB each)<br/>• numatune strict per node<br/>• hugepages per nodeset<br/>• pxb-pcie NUMA 0 + NUMA 1<br/>• hostdev on NUMA-correct buses<br/>• ACPI enabled

    Libvirt->>VM: Start QEMU

    Note over VM: Guest sees:<br/>NUMA 0: 3 CPUs + 3 GiB + GPU + NIC<br/>NUMA 1: 3 CPUs + 3 GiB + GPU + NIC<br/>All numa_node values correct
```

---

## Topology Coordinator Partition Flow

How the coordinator creates partition DeviceClasses and the webhook expands claims.

```mermaid
graph LR
    subgraph "Discovery"
        RS_CPU[ResourceSlice<br/>dra.cpu<br/>2 devices]
        RS_NIC[ResourceSlice<br/>sriovnetwork<br/>8 devices]
        RS_MEM[ResourceSlice<br/>dra.memory<br/>4 devices]
    end

    subgraph "Topology Coordinator"
        RULES[Topology Rules<br/>ConfigMaps]
        DISCOVERY[Device Discovery]
        PARTITION[Partition Builder]
        DC_MGR[DeviceClass Manager]
    end

    subgraph "Partition DeviceClasses"
        DC_E[eighth]
        DC_Q[quarter]
        DC_H[half]
        DC_F[full]
    end

    RS_CPU --> DISCOVERY
    RS_NIC --> DISCOVERY
    RS_MEM --> DISCOVERY
    RULES --> DISCOVERY

    DISCOVERY --> PARTITION
    PARTITION --> DC_MGR

    DC_MGR --> DC_E
    DC_MGR --> DC_Q
    DC_MGR --> DC_H
    DC_MGR --> DC_F
```

```mermaid
sequenceDiagram
    participant User
    participant Webhook as Partition Webhook
    participant API as kube-apiserver
    participant Sched as kube-scheduler

    User->>API: Create ResourceClaim<br/>deviceClassName: ...-quarter<br/>count: 1

    API->>Webhook: Mutating admission

    Webhook->>Webhook: Read PartitionConfig from DeviceClass<br/>subResources: 1x cpu, 4x nic, 1x memory<br/>alignments: matchAttribute numaNode

    Webhook->>API: Mutate claim:<br/>• Replace request with 3 sub-requests<br/>• Add matchAttribute constraint

    Note over API: Expanded claim:<br/>my-quarter-dra-cpu (count: 1)<br/>my-quarter-sriovnetwork (count: 4)<br/>my-quarter-dra-memory (count: 1)<br/>constraint: matchAttribute numaNode

    API->>Sched: Schedule pod with expanded claim
    Sched->>Sched: Allocate all from same NUMA node
```

---

## Device-to-NUMA Mapping (Dell XE9680)

```mermaid
graph TB
    subgraph "NUMA Node 0 — Socket 0"
        CPU0_DEV["CPUs: 0,2,4,6,...,126<br/>(64 cores, even numbers)"]
        GPU0_DEV["GPU VFs: 0000:1b:02.0<br/>(MI300X, vfio-pci)"]
        NIC0_DEV["NIC VFs: 0000:1d:00.2-5<br/>(ConnectX-6, vfio-pci)"]
        MEM0_DEV["Memory: regular + hugepages<br/>(2Mi pages)"]
    end

    subgraph "NUMA Node 1 — Socket 1"
        CPU1_DEV["CPUs: 1,3,5,7,...,127<br/>(64 cores, odd numbers)"]
        GPU1_DEV["GPU VFs: 0000:9d:02.0<br/>(MI300X, vfio-pci)"]
        NIC1_DEV["NIC VFs: 0000:9f:00.2-5<br/>(ConnectX-6, vfio-pci)"]
        MEM1_DEV["Memory: regular + hugepages<br/>(2Mi pages)"]
    end

    subgraph "DRA Attributes Published"
        A0["dra.net/numaNode: 0<br/>dra.cpu/numaNodeID: 0"]
        A1["dra.net/numaNode: 1<br/>dra.cpu/numaNodeID: 1"]
    end

    CPU0_DEV -.-> A0
    NIC0_DEV -.-> A0
    MEM0_DEV -.-> A0

    CPU1_DEV -.-> A1
    NIC1_DEV -.-> A1
    MEM1_DEV -.-> A1
```

---

## KubeVirt Guest PCI NUMA Topology (VEP 115)

```mermaid
graph TB
    subgraph "Guest PCI Topology"
        ROOT["pcie.0<br/>(root bus)"]

        subgraph "pxb-pcie NUMA 0 (bus 253)"
            EXP0["pcie-expander-bus<br/>node: 0"]
            RP0A["pcie-root-port<br/>bus 0xfe"]
            RP0B["pcie-root-port<br/>bus 0xff"]
            GPU0_G["GPU VF<br/>0000:1b:02.0<br/>guest numa=0"]
            NIC0_G["NIC VF<br/>0000:1d:00.3<br/>guest numa=0"]
        end

        subgraph "pxb-pcie NUMA 1 (bus 250)"
            EXP1["pcie-expander-bus<br/>node: 1"]
            RP1A["pcie-root-port<br/>bus 0xfb"]
            RP1B["pcie-root-port<br/>bus 0xfc"]
            GPU1_G["GPU VF<br/>0000:9d:02.0<br/>guest numa=1"]
            NIC1_G["NIC VF<br/>0000:9f:00.2<br/>guest numa=1"]
        end
    end

    ROOT --> EXP0
    ROOT --> EXP1
    EXP0 --> RP0A --> GPU0_G
    EXP0 --> RP0B --> NIC0_G
    EXP1 --> RP1A --> GPU1_G
    EXP1 --> RP1B --> NIC1_G

    subgraph "Guest NUMA Cells"
        CELL0["NUMA 0<br/>CPUs 0-2, 3 GiB<br/>GPU + NIC"]
        CELL1["NUMA 1<br/>CPUs 3-5, 3 GiB<br/>GPU + NIC"]
    end

    GPU0_G -.-> CELL0
    NIC0_G -.-> CELL0
    GPU1_G -.-> CELL1
    NIC1_G -.-> CELL1
```

---

## Known Issues

| Issue | Impact | Status |
|-------|--------|--------|
| Coordinator bug #2: `matchAttribute` uses `nodepartition.dra.k8s.io/numaNode` | Webhook-expanded claims unsatisfiable | Workaround: use `dra.net/numaNode` manually |
| SR-IOV driver needs opaque config | PrepareResources fails without VfConfig | Workaround: default config in DeviceClass |
| CPU pinning needs K8s 1.36 | cpuset swap hack required on K8s 1.34 | Fixed with `DRAConsumableCapacity` (K8s 1.36) |
| KubeVirt ACPI not auto-enabled | Guest PCI `numa_node=-1` without `features.acpi` | Workaround: add `features.acpi: {}` to VM spec |
| Memory driver capacity | PrepareResources fails on K8s 1.34 | Fixed with `DRAConsumableCapacity` (K8s 1.36) |

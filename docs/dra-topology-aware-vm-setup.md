# DRA Topology-Aware VM Setup Guide

**Date:** 2026-04-30

End-to-end setup for topology-aware KubeVirt VMs using DRA for all device allocation. GPU, NIC, CPU, and memory are co-placed on the same NUMA node by the DRA scheduler — all without device plugins.

Two CPU pinning options are supported (see [issues.md](issues.md#cpu-pinning-with-dra-devices--two-options)):
- **Option A** — `cpuManagerPolicy: none`, DRA CPU driver pins via NRI. Multi-NUMA VMs supported.
- **Option B** — `cpuManagerPolicy: static`, custom kubelet DRA topology hints. Single-NUMA VMs.

Verified on:
- Dell R760xa (2x A40 GPUs, CX7 NICs, 2-socket Xeon, 128 CPUs) — Option A + B
- Dell XE8640 (4x H100 SXM5, NVLink, 2-socket Intel, 128 CPUs) — Option A, multi-NUMA VM with 3 GPUs

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  DRA Scheduler                                                       │
│  matchAttribute: resource.kubernetes.io/numaNode                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐               │
│  │ GPU VFIO │ │ NIC (VF) │ │ CPU dev  │ │ Memory   │               │
│  │ NUMA 0   │ │ NUMA 0   │ │ NUMA 0   │ │ NUMA 0   │               │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘               │
└────────────────────────┬────────────────────────────────────────────┘
                         │ ResourceClaim allocated
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Kubelet (custom build)                                              │
│  ┌──────────────────────┐  ┌──────────────────────────────────────┐ │
│  │ DRA Topology Hints   │→│ Topology Manager (restricted)         │ │
│  │ reads numaNode from  │  │ merges hints from all providers      │ │
│  │ ResourceSlice attrs  │  │ selects NUMA 0 for CPU pinning       │ │
│  └──────────────────────┘  └──────────────────────────────────────┘ │
│  ┌──────────────────────┐                                           │
│  │ CPU Manager (static) │  pins vCPUs to NUMA 0 host CPUs          │
│  └──────────────────────┘                                           │
└────────────────────────┬────────────────────────────────────────────┘
                         │ cpuset + VFIO devices
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  KubeVirt VM (guestMappingPassthrough)                               │
│  Guest sees: 1 socket, 1 NUMA node, GPU at 0000:09:00.0             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Kubernetes 1.36+ with DRA enabled (DynamicResourceAllocation feature gate)
- containerd 2.2.3+
- KubeVirt 1.5+ with DRA support
- IOMMU enabled in BIOS (for GPU VFIO passthrough)
- SR-IOV VFs configured on NICs (if NIC passthrough needed)

## Components

| Component | Version/Image | Purpose |
|-----------|---------------|---------|
| Kubelet | Custom build from `johnahull/kubernetes` branch `feature/enforcement-preferred` | DRA topology hints + CPU manager fixes |
| dranet | `ghcr.io/johnahull/dra-topology-drivers/dranet:latest` | NIC DRA driver with topology attrs + VFIO |
| dra-cpu | `ghcr.io/johnahull/dra-topology-drivers/dracpu:latest` | CPU DRA driver with NUMA attrs |
| dra-memory | `ghcr.io/johnahull/dra-topology-drivers/dramemory:latest` | Memory/hugepages DRA driver |
| NVIDIA DRA | GPU Operator with DRA enabled | GPU DRA driver with VFIO + topology attrs |
| KubeVirt | `johnahull/kubevirt` branch `feature/dra-vfio-numa-passthrough-v1.8.1` | Multi-request DRA claim fixes |

---

## Step 1: Custom Kubelet Build

The custom kubelet has three fixes required for DRA-aware CPU pinning:

### Fix 1: DRA Topology Hints (new file)

`pkg/kubelet/cm/dra/topology_hints.go` — Makes the DRA Manager implement `topologymanager.HintProvider`. Reads `resource.kubernetes.io/numaNode` from ResourceSlice device attributes for each allocated device in the pod's ResourceClaims. Returns NUMA topology hints so the topology manager aligns CPU pinning with DRA device placement.

The key requirement: ResourceSlice list calls must include `FieldSelector: "spec.nodeName=" + m.nodeName` — the Node Authorizer denies unscoped list requests.

### Fix 2: CPU Manager Reconciler

`pkg/kubelet/cm/cpumanager/cpu_manager.go` `AddContainer()` — The original code set `lastUpdateState` without writing the cgroup, so the reconciler never corrected cpuset mismatches. Fixed by calling `updateContainerCPUSet` immediately in `AddContainer` and only setting `lastUpdateState` after the update succeeds.

### Fix 3: Manager Registration

`pkg/kubelet/cm/container_manager_linux.go` — Registers the DRA Manager as a topology hint provider: `cm.topologyManager.AddHintProvider(logger, cm.draManager)`. Passes `string(nodeConfig.NodeName)` to `dra.NewManager`.

### Building

```bash
cd ~/devel/kubernetes/kubernetes
git checkout feature/enforcement-preferred
GOTOOLCHAIN=auto go build -mod=vendor -o _output/bin/kubelet ./cmd/kubelet/
```

### Deploying

```bash
scp _output/bin/kubelet <node>:/tmp/kubelet-custom
ssh <node> '
  sudo systemctl stop kubelet
  sudo cp /usr/bin/kubelet /usr/bin/kubelet.bak
  sudo cp /tmp/kubelet-custom /usr/bin/kubelet
  sudo rm -f /var/lib/kubelet/cpu_manager_state
  sudo systemctl start kubelet
'
```

Removing `cpu_manager_state` forces a clean state on policy change.

---

## Step 2: Kubelet Configuration

Edit `/var/lib/kubelet/config.yaml`. Choose one of the two options:

### Option A: DRA CPU Driver Pinning (multi-NUMA)

```yaml
cpuManagerPolicy: none
topologyManagerPolicy: none
featureGates:
  DynamicResourceAllocation: true
  DRAResourceClaimDeviceStatus: true
```

- `none` — disables kubelet CPU pinning; the DRA CPU driver's NRI hook handles cpuset
- `topologyManagerPolicy: none` — no topology hints needed; DRA scheduler handles alignment
- `DRAResourceClaimDeviceStatus` — enables KEP-5304 device metadata projection

The DRA CPU driver allocates CPU devices per NUMA node and pins the compute container via NRI `CreateContainer` hook. Multi-NUMA VMs get CPUs from all allocated NUMA nodes.

### Option B: Kubelet DRA Topology Hints (single-NUMA)

```yaml
cpuManagerPolicy: static
topologyManagerPolicy: restricted
reservedSystemCPUs: "0-3"
featureGates:
  DynamicResourceAllocation: true
  DRAResourceClaimDeviceStatus: true
```

- `static` — enables exclusive CPU pinning for Guaranteed QoS pods
- `restricted` — rejects pods if topology hints can't be satisfied
- `reservedSystemCPUs` — excludes CPUs 0-3 from allocation (adjust for your system)

Requires the custom kubelet with DRA topology hints (Step 1). The topology manager reads `numaNode` from ResourceSlice and pins CPUs to the same NUMA as DRA devices.

### After changing

```bash
sudo rm -f /var/lib/kubelet/cpu_manager_state
sudo systemctl restart kubelet
```

---

## Step 3: Hugepages

KubeVirt VMs with `guestMappingPassthrough` require hugepages.

```bash
# Set 8192 x 2Mi pages = 16Gi
sudo sysctl -w vm.nr_hugepages=8192

# Persist across reboots
echo "vm.nr_hugepages=8192" | sudo tee /etc/sysctl.d/99-hugepages.conf

# Restart kubelet to pick up new hugepage count
sudo systemctl restart kubelet

# Verify
kubectl describe node | grep hugepages
```

The node should show `hugepages-2Mi: 16Gi` in allocatable resources.

---

## Step 4: DRA Drivers

### 4a. dranet (Network)

Discovers all NICs (PFs and SR-IOV VFs) and publishes standardized topology attributes.

```yaml
# dranet-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dranet
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: dranet
  template:
    metadata:
      labels:
        app: dranet
    spec:
      hostNetwork: true
      hostPID: true
      tolerations:
      - operator: Exists
      containers:
      - name: dranet
        image: ghcr.io/johnahull/dra-topology-drivers/dranet:latest
        imagePullPolicy: IfNotPresent
        args:
        - /dranet
        - --v=4
        - --hostname-override=$(NODE_NAME)
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/plugins
        - name: plugin-registry
          mountPath: /var/lib/kubelet/plugins_registry
        - name: nri-plugin
          mountPath: /var/run/nri
        - name: netns
          mountPath: /var/run/netns
          mountPropagation: HostToContainer
        - name: cdi
          mountPath: /var/run/cdi
        - name: sys
          mountPath: /sys
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/plugins
      - name: plugin-registry
        hostPath:
          path: /var/lib/kubelet/plugins_registry
      - name: nri-plugin
        hostPath:
          path: /var/run/nri
      - name: netns
        hostPath:
          path: /var/run/netns
      - name: cdi
        hostPath:
          path: /var/run/cdi
          type: DirectoryOrCreate
      - name: sys
        hostPath:
          path: /sys
```

### 4b. CPU Driver

The CPU driver supports two modes:
- **`individual`** (recommended) — one device per logical CPU. Claims use `count: N` to request N CPUs. Multiple claims can share a NUMA node. Use `matchAttribute: resource.kubernetes.io/numaNode` to align CPUs with GPUs/NICs.
- **`grouped`** — one device per NUMA node. Only one claim per NUMA. Use for single-claim-per-NUMA workloads (topology coordinator partitions).

```yaml
# dracpu-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dracpu
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: dracpu
  template:
    metadata:
      labels:
        app: dracpu
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: dracpu
        image: ghcr.io/johnahull/dra-topology-drivers/dracpu:latest
        imagePullPolicy: IfNotPresent
        command: ["/dracpu"]
        args:
        - --hostname-override=$(NODE_NAME)
        - --cpu-device-mode=individual
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: plugins-registry
          mountPath: /var/lib/kubelet/plugins_registry
        - name: plugins
          mountPath: /var/lib/kubelet/plugins/dra.cpu
        - name: cdi
          mountPath: /var/run/cdi
      volumes:
      - name: plugins-registry
        hostPath:
          path: /var/lib/kubelet/plugins_registry
      - name: plugins
        hostPath:
          path: /var/lib/kubelet/plugins/dra.cpu
          type: DirectoryOrCreate
      - name: cdi
        hostPath:
          path: /var/run/cdi
          type: DirectoryOrCreate
```

### 4c. Memory Driver

```yaml
# dramemory-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dramemory
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: dramemory
  template:
    metadata:
      labels:
        app: dramemory
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: dramemory
        image: ghcr.io/johnahull/dra-topology-drivers/dramemory:latest
        imagePullPolicy: IfNotPresent
        args:
        - --hostname-override=$(NODE_NAME)
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: plugins-registry
          mountPath: /var/lib/kubelet/plugins_registry
        - name: plugins
          mountPath: /var/lib/kubelet/plugins/dra.memory
        - name: cdi
          mountPath: /var/run/cdi
      volumes:
      - name: plugins-registry
        hostPath:
          path: /var/lib/kubelet/plugins_registry
      - name: plugins
        hostPath:
          path: /var/lib/kubelet/plugins/dra.memory
          type: DirectoryOrCreate
      - name: cdi
        hostPath:
          path: /var/run/cdi
          type: DirectoryOrCreate
```

### 4d. NVIDIA GPU DRA Driver

Install via GPU Operator + DRA Helm chart:

```bash
# GPU Operator (loads nvidia kernel module, manages one GPU for NVML)
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=true

# NVIDIA DRA driver (VFIO passthrough + topology attributes)
helm install nvidia-dra nvidia/nvidia-dra-driver-gpu \
  --namespace nvidia-dra --create-namespace \
  --set nvidiaDriverRoot=/usr \
  --set gpuResourcesEnabledOverride=true \
  --set features.passthrough.enabled=true \
  --set resources.gpus.enabled=true
```

After install, enable feature gates on the `gpus` container:

```bash
kubectl set env daemonset/nvidia-dra-driver-gpu-kubelet-plugin \
  -n nvidia-dra -c gpus \
  FEATURE_GATES=PassthroughSupport=true,DeviceMetadata=true
```

- `PassthroughSupport` — enables VFIO device discovery and `gpu-vfio-*` devices
- `DeviceMetadata` — enables KEP-5304 metadata (pciBusID, numaNode) in PrepareResult

#### H100 SXM5 / NVLink Systems

On H100 SXM5 (HGX platforms with NVLink), the nvidia driver's sysfs unbind hangs indefinitely during NVLink fabric reconfiguration (D-11). GPUs must be pre-bound to vfio-pci at boot:

```bash
# Add to kernel cmdline (via grubby or /etc/default/grub)
grubby --update-kernel=ALL --args="vfio-pci.ids=10de:2330 iommu=on"
```

This binds all H100 GPUs to vfio-pci at boot. The GPU operator will load the nvidia module and bind one GPU to nvidia for NVML. The remaining GPUs stay on vfio-pci and are available for VFIO passthrough.

**Custom NVIDIA DRA driver image required:** The stock driver needs patches for:
- VFIO discovery filter — only advertise GPUs actually on vfio-pci (D-13)
- Unconfigure skip — don't rebind pre-bound GPUs to nvidia (D-14)
- Sysfs container fix — check `/sys/module/vfio_pci` without host-root prefix (D-15)

Build from `johnahull/dra-driver-nvidia-gpu` branch `feature/standardized-topology-attrs`:

```bash
GOTOOLCHAIN=auto go build -ldflags "-X sigs.k8s.io/dra-driver-nvidia-gpu/internal/info.version=v25.12.0" \
  -o /tmp/gpu-kubelet-plugin ./cmd/gpu-kubelet-plugin/

# Build container with patched binary
cat > /tmp/Dockerfile.nvidia-dra << 'EOF'
FROM nvcr.io/nvidia/k8s-dra-driver-gpu:v25.12.0
COPY gpu-kubelet-plugin /usr/bin/gpu-kubelet-plugin
EOF
podman build -f /tmp/Dockerfile.nvidia-dra -t localhost/nvidia-dra-driver:patched /tmp/

# Transfer to node and update daemonset
podman save localhost/nvidia-dra-driver:patched | ssh <node> "sudo ctr -n k8s.io images import -"
kubectl set image daemonset/nvidia-dra-driver-gpu-kubelet-plugin \
  -n nvidia-dra gpus=localhost/nvidia-dra-driver:patched
```

---

## Step 5: DeviceClasses

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.net
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.net'"
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.net-sriov-vf
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.net' && device.attributes['dra.net/isSriovVf'].BoolValue"
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.cpu
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.cpu'"
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.memory
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.memory'"
```

The `vfio.gpu.nvidia.com` DeviceClass is created automatically by the NVIDIA DRA driver.

---

## Step 6: KubeVirt Configuration

### Feature Gates

```bash
kubectl patch kubevirt kubevirt -n kubevirt --type merge -p '{
  "spec": {
    "configuration": {
      "developerConfiguration": {
        "featureGates": [
          "HostDevices",
          "DRA",
          "HostDevicesWithDRA",
          "GPUsWithDRA",
          "CPUManager",
          "ReservedOverheadMemlock"
        ]
      }
    }
  }
}'
```

All six feature gates are required:
- `DRA` — enables DRA resource claims in VMI specs
- `GPUsWithDRA` — GPU passthrough via DRA claims
- `HostDevicesWithDRA` — host device passthrough via DRA claims
- `HostDevices` — general host device support
- `CPUManager` — dedicated CPU placement
- `ReservedOverheadMemlock` — allows `reservedOverhead.addedOverhead` for VFIO memory locking

### Custom KubeVirt Build

Branch `feature/dra-vfio-numa-passthrough-v1.8.2` on `johnahull/kubevirt` contains:

**virt-controller fixes:**
1. `copyResourceClaims` deduplicates by `{Name, Request}` not just `Name`
2. `WithExtraResourceClaims` adds all VMI claims without a Request filter
3. `WithGPUsDRA`/`WithHostDevicesDRA` simplified to avoid duplicate claim name errors
4. VFIO capabilities (CAP_IPC_LOCK, SYS_RAWIO, unlimited MEMLOCK) for DRA GPU pods

**virt-launcher fixes (multi-NUMA):**
5. `buildDRANUMACells` — discovers NUMA nodes from KEP-5304 metadata (scans all `*-metadata.json` files) and creates guest NUMA cells instead of using kubelet cpuset (KV-9)
6. `buildDRANUMAOverrides` — iterates both `HostDevices` and `GPUs` for PCI-to-NUMA mapping (KV-10)
7. `PlacePCIDevicesWithNUMAAlignment` — creates `pxb-pcie` expander buses for correct guest NUMA affinity

Build the virt-launcher inside a CentOS Stream 9 container (matching the base image for libvirt/libnbd):

```bash
cd ~/devel/kubevirt/kubevirt
podman run --rm -v $(pwd):/src:Z -w /src quay.io/centos/centos:stream9 bash -c \
  "dnf install -y epel-release && dnf config-manager --set-enabled crb && \
   dnf install -y golang gcc-c++ libvirt-devel libnbd-devel && \
   go build -o /src/_out/virt-launcher ./cmd/virt-launcher/"

# Build container image
cat > /tmp/Dockerfile.virt-launcher << 'EOF'
FROM quay.io/kubevirt/virt-launcher:v1.8.2
COPY _out/virt-launcher /usr/bin/virt-launcher
EOF
podman build -f /tmp/Dockerfile.virt-launcher -t localhost/virt-launcher:dra-multi-numa .

# Deploy by tagging over the stock image on the node
podman save localhost/virt-launcher:dra-multi-numa | \
  ssh <node> "sudo ctr -n k8s.io images import -; \
              sudo ctr -n k8s.io images tag localhost/virt-launcher:dra-multi-numa quay.io/kubevirt/virt-launcher:v1.8.2"

# Same approach for custom virt-controller
go build -o _out/virt-controller ./cmd/virt-controller/
podman build -f /tmp/Dockerfile.virt-controller -t localhost/virt-controller:dra-fix .
podman save localhost/virt-controller:dra-fix | \
  ssh <node> "sudo ctr -n k8s.io images import -; \
              sudo ctr -n k8s.io images tag localhost/virt-controller:dra-fix quay.io/kubevirt/virt-controller:v1.8.2"

# Restart KubeVirt components
kubectl delete pods -n kubevirt -l kubevirt.io=virt-controller
kubectl delete pods -n kubevirt -l kubevirt.io=virt-handler
```

---

## Step 7: Verification

### Check DRA Drivers

```bash
kubectl get resourceslices -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
drivers = set(s['spec']['driver'] for s in data['items'])
print('Drivers:', sorted(drivers))
"
```

Expected: `dra.cpu`, `dra.memory`, `dra.net`, `gpu.nvidia.com`

### Check Topology Attributes

```bash
kubectl get resourceslices -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data['items']:
    driver = s['spec']['driver']
    for d in s['spec'].get('devices', []):
        attrs = d.get('attributes', {})
        numa = attrs.get('resource.kubernetes.io/numaNode', {}).get('int', '?')
        print(f'{driver:40s} {d[\"name\"]:25s} NUMA={numa}')
"
```

All devices should have `resource.kubernetes.io/numaNode` set.

---

## Step 8: Create a Topology-Aware VM

### ResourceClaimTemplate (single-NUMA, with per-CPU devices)

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: vm-numa0-devices
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: vfio.gpu.nvidia.com
      - name: nic
        exactly:
          deviceClassName: dra.net
          selectors:
          - cel:
              expression: '!(has(device.attributes["dra.net"].vfioUnsafe) && device.attributes["dra.net"].vfioUnsafe)'
      - name: cpus
        exactly:
          deviceClassName: dra.cpu
          count: 8
      - name: mem
        exactly:
          deviceClassName: dra.memory
      constraints:
      - requests: ["gpu", "nic", "cpus", "mem"]
        matchAttribute: resource.kubernetes.io/numaNode
```

The `matchAttribute` constraint forces the scheduler to pick devices that share the same `numaNode` value across all four drivers. With `--cpu-device-mode=individual`, each CPU is a separate device, so `count: 8` selects 8 CPUs from the matching NUMA node. Multiple claims can each get different CPU counts from the same NUMA node.

### VirtualMachine

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: dra-topology-vm
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 4
          sockets: 1
          threads: 1
          dedicatedCpuPlacement: true
          numa:
            guestMappingPassthrough: {}
        memory:
          guest: 4Gi
          hugepages:
            pageSize: 2Mi
          reservedOverhead:
            addedOverhead: 4Gi
        devices:
          gpus:
          - name: gpu0
            claimName: numa0
            requestName: gpu
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
        resources:
          requests:
            memory: 4Gi
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/containerdisks/fedora:40
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd:
              expire: false
            ssh_pwauth: true
      resourceClaims:
      - name: numa0
        resourceClaimTemplateName: vm-numa0-devices
```

Key settings:
- `dedicatedCpuPlacement: true` — exclusive CPU pinning (Guaranteed QoS)
- `guestMappingPassthrough: {}` — guest NUMA topology mirrors host device placement
- `hugepages.pageSize: 2Mi` — required for NUMA-aware memory binding
- `reservedOverhead.addedOverhead: 4Gi` — additional locked memory for VFIO DMA
- `matchAttribute: resource.kubernetes.io/numaNode` — forces single-NUMA alignment

### Multi-NUMA VM (Option A, all GPUs)

For multi-NUMA VMs, use separate requests per GPU with CEL selectors for each NUMA node. No `matchAttribute` constraint — devices from both NUMA nodes are requested explicitly.

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: vm-multi-numa-devices
spec:
  spec:
    devices:
      requests:
      - name: gpu0
        exactly:
          deviceClassName: vfio.gpu.nvidia.com
          selectors:
          - cel:
              expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 0"
      - name: gpu1
        exactly:
          deviceClassName: vfio.gpu.nvidia.com
          selectors:
          - cel:
              expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 0"
      - name: gpu2
        exactly:
          deviceClassName: vfio.gpu.nvidia.com
          selectors:
          - cel:
              expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 1"
      - name: cpu0
        exactly:
          deviceClassName: dra.cpu
          selectors:
          - cel:
              expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 0"
      - name: cpu1
        exactly:
          deviceClassName: dra.cpu
          selectors:
          - cel:
              expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 1"
      - name: mem0
        exactly:
          deviceClassName: dra.memory
          selectors:
          - cel:
              expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 0"
      - name: mem1
        exactly:
          deviceClassName: dra.memory
          selectors:
          - cel:
              expression: "device.attributes[\"resource.kubernetes.io\"].numaNode == 1"
```

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: dra-multi-numa-vm
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 4
          sockets: 2
          threads: 1
          dedicatedCpuPlacement: true
          numa:
            guestMappingPassthrough: {}
        memory:
          guest: 8Gi
          hugepages:
            pageSize: 2Mi
          reservedOverhead:
            addedOverhead: 4Gi
        devices:
          gpus:
          - name: gpu0
            claimName: devices
            requestName: gpu0
          - name: gpu1
            claimName: devices
            requestName: gpu1
          - name: gpu2
            claimName: devices
            requestName: gpu2
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/containerdisks/fedora:41
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd:
              expire: false
            ssh_pwauth: true
      resourceClaims:
      - name: devices
        resourceClaimTemplateName: vm-multi-numa-devices
```

Key differences from single-NUMA:
- `sockets: 2` — guest sees 2 sockets (1 per NUMA node)
- Separate GPU requests per device (KubeVirt requires 1 device per request for KEP-5304 metadata)
- CEL selectors target specific NUMA nodes instead of `matchAttribute`
- `reservedOverhead: 4Gi` — needed for 3 GPU VFIO DMA mappings
- Requires Option A (`cpuManagerPolicy: none`) — the DRA CPU driver pins CPUs from both NUMA nodes
- Requires custom virt-launcher from `johnahull/kubevirt` `feature/dra-vfio-numa-passthrough-v1.8.2` for multi-NUMA guest topology from KEP-5304 metadata

The guest will show 2 NUMA nodes with GPUs on the correct node:
- Guest NUMA 0: gpu0 + gpu1 (host NUMA 0)
- Guest NUMA 1: gpu2 (host NUMA 1)

#### KubeVirt cpumanager label

With `cpuManagerPolicy: none`, KubeVirt's virt-handler sets `kubevirt.io/cpumanager=false` on the node, which blocks scheduling for `dedicatedCpuPlacement` VMs. Set the label manually before creating the VM:

```bash
kubectl label node <node> kubevirt.io/cpumanager=true --overwrite
```

The virt-handler will reset it periodically. Apply the label just before `kubectl apply` of the VM manifest. Once the pod is scheduled and running, the label can be `false` without affecting the running VM.

### Verify

```bash
# Check VM is running
kubectl get vmi dra-topology-vm

# Check CPU pinning
cat /var/lib/kubelet/cpu_manager_state | python3 -m json.tool

# Check DRA allocation
kubectl get resourceclaims -o json | python3 -c "
import json, sys
for c in json.load(sys.stdin)['items']:
    print(c['metadata']['name'])
    for r in c.get('status',{}).get('allocation',{}).get('devices',{}).get('results',[]):
        print(f'  {r[\"request\"]:8s} -> {r[\"driver\"]:30s} {r[\"device\"]}')
"

# Check kubelet logs for DRA topology hints
journalctl -u kubelet | grep "DRA topology"

# SSH into VM
sshpass -p fedora ssh fedora@<vm-ip>
lscpu | grep NUMA
# Should show: NUMA node(s): 1
```

---

## How It Works (Data Flow)

1. **Scheduling**: The DRA scheduler evaluates the `matchAttribute: resource.kubernetes.io/numaNode` constraint and picks GPU, CPU device, and memory device that all have the same `numaNode` value (e.g., all NUMA 0).

2. **Pod Admission**: The kubelet admits the pod. The topology manager queries all HintProviders:
   - CPU Manager generates hints based on available CPUs per NUMA
   - DRA Manager (`topology_hints.go`) reads the ResourceClaim allocations, looks up each device's `numaNode` from the ResourceSlice, and returns `{NUMANodeAffinity: 0}` (NUMA 0)

3. **Topology Decision**: The topology manager merges hints and selects NUMA 0 as the best fit.

4. **CPU Allocation**: The CPU Manager allocates 4 exclusive CPUs from NUMA 0 (e.g., CPUs 4,6,68,70).

5. **Container Creation**: `PreCreateContainer` sets `CpusetCpus: "4,6,68,70"` in the CRI config. `AddContainer` calls `UpdateContainerResources` to ensure the cgroup is correct before the container starts.

6. **VM Launch**: KubeVirt's virt-launcher reads `cpuset.cpus.effective` (4,6,68,70), maps them to host NUMA cell 0, generates libvirt XML with `<numatune><memnode cellid='0' mode='strict' nodeset='0'/></numatune>`, and starts QEMU with hugepages bound to NUMA 0 and the GPU passed through via VFIO.

---

## Troubleshooting

### DRA topology hints not generated

Check kubelet logs:
```bash
journalctl -u kubelet | grep "DRA topology"
```

If no output, verify:
- The DRA Manager is registered as a HintProvider (requires custom kubelet)
- `topologyManagerPolicy` is `restricted` or `best-effort` (not `none`)
- The pod has ResourceClaims with allocated devices

### CPUs pinned to wrong NUMA node

Check cgroup cpuset:
```bash
# Find the compute container's cgroup
find /sys/fs/cgroup -name "cri-containerd-*" -path "*<pod-uid>*" -exec sh -c 'echo "$(basename {}): $(cat {}/cpuset.cpus)"' \;

# Compare with CPU manager state
cat /var/lib/kubelet/cpu_manager_state | python3 -m json.tool
```

If cgroup doesn't match state, the kubelet needs the `AddContainer` fix (Fix 2 and 3 above).

### VM fails with `set_mempolicy: Invalid argument`

The QEMU memory binding is targeting the wrong NUMA node. Check:
1. The compute container's `cpuset.cpus` matches the CPU manager state
2. The cpuset CPUs are on the expected NUMA node: `cat /sys/devices/system/cpu/cpu<N>/topology/physical_package_id`
3. The `cpuset.mems` allows the correct NUMA node

### ResourceSlice list returns empty

The kubelet's Node Authorizer requires `spec.nodeName` field selector. Verify the custom kubelet includes this fix in `lookupDeviceNUMANode`.

### Hugepages insufficient

```bash
kubectl describe node | grep hugepages
# Must show enough hugepages-2Mi for guest memory + overhead
# Formula: (guest memory + addedOverhead) / 2Mi
```

---

## Repositories

| Repository | Branch | Changes |
|------------|--------|---------|
| `johnahull/kubernetes` | `feature/enforcement-preferred` | DRA topology hints, CPU manager fixes (option B) |
| `johnahull/kubernetes` | `feature/dra-topology-hints-v1.36` | Same patches on v1.36.0 base (for XE8640) |
| `johnahull/kubevirt` | `feature/dra-vfio-numa-passthrough-v1.8.2` | DRA claim fixes + DRA NUMA cells from KEP-5304 + GPU pxb-pcie placement |
| `johnahull/dra-driver-nvidia-gpu` | `feature/standardized-topology-attrs` | VFIO discovery filter, Unconfigure skip, sysfs fix, topology attrs |
| `johnahull/dranet` | `feature/standardized-topology-attrs` | Standardized topology attributes, VFIO support |

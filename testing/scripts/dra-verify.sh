#!/bin/bash
# dra-verify.sh — Verify DRA topology-aware co-placement stack
#
# Usage:
#   dra-verify.sh slices                     Show hardware summary from ResourceSlices
#   dra-verify.sh topology                   Show devices grouped by pcieRoot, numaNode, cpuSocketID
#   dra-verify.sh drivers                    Show DRA driver status
#   dra-verify.sh attributes                 Show ResourceSlice topology attributes
#   dra-verify.sh deviceclasses               Show topology coordinator device classes
#   dra-verify.sh claims [-n ns]             Show allocated claims with pods/VMs and devices
#   dra-verify.sh alignment [pod] [-n ns]    Show device NUMA/pcieRoot/socket alignment
#   dra-verify.sh cpupinning [pod] [-n ns]   Show cpuset vs device NUMA
#   dra-verify.sh vfio                       Show VFIO-bound devices and CDI specs
#   dra-verify.sh metadata [pod] [-n ns]     Show KEP-5304 metadata in pod
#   dra-verify.sh guest [vm] [-n ns]         Show guest NUMA topology in VM
#   dra-verify.sh all [-n ns]                Run all checks

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

OK="${GREEN}✓${NC}"
WARN="${YELLOW}!${NC}"
FAIL="${RED}✗${NC}"

# ── Argument parsing ──────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

NAMESPACE=""
TARGET=""
VERBOSE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE="1"; shift ;;
        -h|--help) CMD="help"; shift ;;
        *) TARGET="$1"; shift ;;
    esac
done

ns_flag() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "-n $NAMESPACE"
    else
        echo "-A"
    fi
}

section() {
    echo ""
    echo -e "${BOLD}${CYAN}═══ $1 ═══${NC}"
    echo ""
}

# ── drivers ───────────────────────────────────────────────────────────────────

cmd_drivers() {
    section "DRA Driver Status"

    echo -e "${BOLD}DaemonSets:${NC}"
    kubectl get ds -A -o wide 2>/dev/null | grep -i "dra\|gpu\|sriov\|dranet\|nvme\|cpu.*driver\|memory.*driver" || echo -e "  ${DIM}(no DRA daemonsets found)${NC}"
    echo ""

    echo -e "${BOLD}Driver Pods:${NC}"
    kubectl get pods -A -o wide 2>/dev/null | grep -i "dra\|gpu.*dra\|gpu.*kubelet\|sriov\|dranet\|nvme\|cpu.*driver\|memory.*driver" || echo -e "  ${DIM}(no DRA driver pods found)${NC}"
    echo ""

    echo -e "${BOLD}ResourceSlices (per driver):${NC}"
    kubectl get resourceslices -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
drivers = {}
for rs in data.get('items', []):
    driver = rs['spec']['driver']
    node = rs['spec'].get('nodeName', rs['spec'].get('pool', {}).get('name', '?'))
    devices = rs['spec'].get('devices', []) or []
    if driver not in drivers:
        drivers[driver] = {'nodes': set(), 'devices': 0}
    drivers[driver]['nodes'].add(node)
    drivers[driver]['devices'] += len(devices)

if not drivers:
    print('  (no ResourceSlices found)')
else:
    for d in sorted(drivers):
        info = drivers[d]
        nodes = ', '.join(sorted(info['nodes']))
        print(f'  \033[1m{d}\033[0m: {info[\"devices\"]} devices on {nodes}')
" 2>/dev/null
    echo ""

    echo -e "${BOLD}Kubelet Plugin Registration:${NC}"
    local reg_dir="/var/lib/kubelet/plugins_registry"
    if [[ -d "$reg_dir" ]]; then
        ls -la "$reg_dir"/*dra* "$reg_dir"/*gpu* "$reg_dir"/*sriov* "$reg_dir"/*dranet* "$reg_dir"/*nvme* "$reg_dir"/*cpu* "$reg_dir"/*memory* 2>/dev/null | while read -r line; do
            echo "  $line"
        done
        if [[ -z "$(ls "$reg_dir"/*dra* "$reg_dir"/*gpu* "$reg_dir"/*sriov* "$reg_dir"/*dranet* 2>/dev/null)" ]]; then
            echo -e "  ${DIM}(no DRA plugins registered — run on the node, not remotely)${NC}"
        fi
    else
        echo -e "  ${DIM}(not running on a node — kubelet plugin dir not found)${NC}"
    fi
}

# ── attributes ────────────────────────────────────────────────────────────────

cmd_attributes() {
    section "ResourceSlice Topology Attributes"

    kubectl get resourceslices -o json 2>/dev/null | python3 -c "
import json, sys

data = json.load(sys.stdin)
TOPO_ATTRS = [
    'resource.kubernetes.io/numaNode',
    'resource.kubernetes.io/cpuSocketID',
    'resource.kubernetes.io/pcieRoot',
    'resource.kubernetes.io/pciBusID',
]
# Also check vendor-specific NUMA attrs
NUMA_VENDOR = ['numaNode', 'numa', 'numaNodeID']

drivers = {}
for rs in data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        name = dev['name']
        attrs = dev.get('attributes', {})

        # Extract topology values
        topo = {}
        for key in TOPO_ATTRS:
            if key in attrs:
                val = attrs[key]
                topo[key.split('/')[-1]] = list(val.values())[0]

        # Check vendor NUMA
        for vk in NUMA_VENDOR:
            for ak, av in attrs.items():
                aname = ak.split('/')[-1] if '/' in ak else ak
                if aname == vk and vk not in [k.split('/')[-1] for k in TOPO_ATTRS]:
                    domain = ak.split('/')[0] if '/' in ak else ''
                    topo[f'{domain}/{vk}' if domain else vk] = list(av.values())[0]

        if driver not in drivers:
            drivers[driver] = []
        drivers[driver].append({'name': name, 'topo': topo})

for driver in sorted(drivers):
    devs = drivers[driver]
    print(f'\033[1m{driver}\033[0m ({len(devs)} devices):')

    # Header
    all_keys = set()
    for d in devs:
        all_keys.update(d['topo'].keys())
    keys = sorted(all_keys)

    hdr = f'  {\"Device\":<20}'
    for k in keys:
        hdr += f'{k:<16}'
    print(f'\033[2m{hdr}\033[0m')

    for d in sorted(devs, key=lambda x: x['name']):
        line = f'  {d[\"name\"]:<20}'
        for k in keys:
            v = d['topo'].get(k, '-')
            line += f'{str(v):<16}'

        # Check for missing standard attrs
        missing = []
        if 'numaNode' not in d['topo']:
            missing.append('numaNode')
        if 'pciBusID' not in d['topo'] and 'cpuSocketID' not in d['topo']:
            # PCI devices need pciBusID, non-PCI need cpuSocketID
            pass

        if missing:
            line += f'  \033[33m(missing: {\", \".join(missing)})\033[0m'
        print(line)
    print()
" 2>/dev/null
}

# ── claims ───────────────────────────────────────────────────────────────────

cmd_claims() {
    section "Allocated Resource Claims"

    local nf
    nf=$(ns_flag)

    { kubectl get resourceclaims $nf -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceslices -o json 2>/dev/null; echo "---SEP---"; kubectl get vmi $nf -o json 2>/dev/null; } | python3 -c "
import json, sys

raw = sys.stdin.read()
parts = raw.split('---SEP---')
claims_data = json.loads(parts[0])
slices_data = json.loads(parts[1])
try:
    vmi_data = json.loads(parts[2])
except:
    vmi_data = {'items': []}

# Build device attr lookup
device_attrs = {}
for rs in slices_data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        attrs = dev.get('attributes', {})
        topo = {}
        for key, val in attrs.items():
            short = key.split('/')[-1] if '/' in key else key
            if short in ('numaNode', 'numa', 'numaNodeID', 'pciBusID', 'pcieRoot', 'cpuSocketID', 'productName'):
                topo[short] = list(val.values())[0]
        device_attrs[f'{driver}/{dev[\"name\"]}'] = topo

# Build VMI name lookup from pod names
vmi_by_pod_prefix = {}
for vmi in vmi_data.get('items', []):
    name = vmi['metadata']['name']
    ns = vmi['metadata']['namespace']
    vmi_by_pod_prefix[f'virt-launcher-{name}-'] = f'{ns}/{name}'

claims = claims_data.get('items', [])
if not claims:
    print('No resource claims found')
    sys.exit(0)

for c in sorted(claims, key=lambda x: x['metadata']['name']):
    cname = c['metadata']['name']
    ns = c['metadata']['namespace']
    state = c.get('status', {}).get('allocation', {})
    reserved = c.get('status', {}).get('reservedFor', [])

    if not state:
        print(f'\033[2m{ns}/{cname}: pending\033[0m')
        continue

    # Find pod/VM
    pod_name = reserved[0]['name'] if reserved else '(unreserved)'
    vm_name = ''
    for prefix, vmi_ref in vmi_by_pod_prefix.items():
        if pod_name.startswith(prefix):
            vm_name = vmi_ref
            break

    header = f'\033[1m{ns}/{cname}\033[0m'
    if vm_name:
        header += f'  →  VM \033[1;35m{vm_name}\033[0m'
    else:
        header += f'  →  pod \033[1;36m{pod_name}\033[0m'
    print(header)

    constraints = c.get('spec', {}).get('devices', {}).get('constraints', [])
    if constraints:
        for con in constraints:
            ma = con.get('matchAttribute', '')
            reqs = con.get('requests', [])
            if ma:
                short_ma = ma.split('/')[-1] if '/' in ma else ma
                req_str = ', '.join(reqs) if reqs else 'all'
                print(f'  \033[2mconstraint: matchAttribute={short_ma} requests=[{req_str}]\033[0m')

    spec_requests = c.get('spec', {}).get('devices', {}).get('requests', [])
    req_summaries = []
    for req in spec_requests:
        exactly = req.get('exactly', {})
        name = req.get('name', '?')
        count = exactly.get('count', 1)
        dc = exactly.get('deviceClassName', '?')
        dc_short = dc.split('.')[-1] if '.' in dc else dc
        if count > 1:
            req_summaries.append(f'{name}: {count}x {dc_short}')
    if req_summaries:
        req_summary_str = ', '.join(req_summaries)
        print(f'  \033[2mrequests: {req_summary_str}\033[0m')

    results = state.get('devices', {}).get('results', [])
    if not results:
        print('  (no devices)')
        print()
        continue

    print(f'  {\"Request\":<12}{\"Driver\":<25}{\"Device\":<20}{\"NUMA\":<6}{\"pcieRoot\":<16}{\"PCI Bus ID\":<18}{\"Product\":<30}')
    print(f'  {\"─\"*12}{\"─\"*25}{\"─\"*20}{\"─\"*6}{\"─\"*16}{\"─\"*18}{\"─\"*30}')

    numas = set()
    roots = set()
    for r in results:
        driver = r['driver']
        device = r['device']
        request = r['request']
        dev_key = f'{driver}/{device}'
        topo = device_attrs.get(dev_key, {})

        numa = topo.get('numaNode', topo.get('numa', topo.get('numaNodeID', '-')))
        root = topo.get('pcieRoot', '-')
        pci = topo.get('pciBusID', '-')
        product = str(topo.get('productName', '-'))[:28]

        driver_short = driver if len(driver) <= 23 else driver[:21] + '..'
        print(f'  {request:<12}{driver_short:<25}{device:<20}{str(numa):<6}{str(root):<16}{str(pci):<18}{product:<30}')

        if root != '-':
            roots.add(str(root))

        if numa != '-':
            numas.add(str(numa))

    print()
    if len(numas) == 1:
        print(f'  \033[32m✓ All devices on NUMA {numas.pop()}\033[0m')
    elif len(numas) > 1:
        numa_list = ', '.join(sorted(numas))
        print(f'  \033[33m! Multi-NUMA: devices on NUMA {numa_list}\033[0m')

    if len(roots) == 1:
        print(f'  \033[32m✓ All PCI devices on pcieRoot {roots.pop()}\033[0m')
    elif len(roots) > 1:
        root_list = ', '.join(sorted(roots))
        print(f'  \033[33m! Multiple pcieRoots: {root_list}\033[0m')
    print()
" 2>/dev/null
}

# ── alignment ─────────────────────────────────────────────────────────────────

cmd_alignment() {
    section "Device NUMA Alignment"

    local target_pod="$TARGET"
    local nf
    nf=$(ns_flag)

    # Get claims and slices together
    { kubectl get resourceclaims $nf -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceslices -o json 2>/dev/null; } | python3 -c "
import json, sys

raw = sys.stdin.read()
parts = raw.split('---SEP---')
claims_data = json.loads(parts[0])
slices_data = json.loads(parts[1])

target_pod = '$target_pod'

# Build device attr lookup from ResourceSlices
device_attrs = {}  # 'driver/device' -> {numaNode, pcieRoot, cpuSocketID}
for rs in slices_data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        name = dev['name']
        attrs = dev.get('attributes', {})
        topo = {}
        for key, val in attrs.items():
            short = key.split('/')[-1] if '/' in key else key
            domain = key.split('/')[0] if '/' in key else ''
            if short in ('numaNode', 'numa', 'numaNodeID', 'pcieRoot', 'pciBusID', 'cpuSocketID'):
                topo[short] = list(val.values())[0]
        device_attrs[f'{driver}/{name}'] = topo

# Process claims
pods = {}
for c in claims_data.get('items', []):
    reserved = c.get('status', {}).get('reservedFor', [])
    if not reserved:
        continue
    pod = reserved[0]['name']
    ns = c['metadata']['namespace']
    if target_pod and target_pod != pod:
        continue

    key = f'{ns}/{pod}'
    if key not in pods:
        pods[key] = []

    for r in c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', []):
        driver = r['driver']
        device = r['device']
        request = r['request']
        dev_key = f'{driver}/{device}'
        topo = device_attrs.get(dev_key, {})
        pods[key].append({
            'driver': driver,
            'device': device,
            'request': request,
            'numa': topo.get('numaNode', topo.get('numa', topo.get('numaNodeID', '?'))),
            'pcieRoot': topo.get('pcieRoot', '-'),
            'socketID': topo.get('cpuSocketID', '-'),
            'pciBusID': topo.get('pciBusID', '-'),
        })

if not pods:
    if target_pod:
        print(f'No claims found for pod {target_pod}')
    else:
        print('No allocated claims found')
    sys.exit(0)

for pod_key in sorted(pods):
    devices = pods[pod_key]
    print(f'\033[1m{pod_key}\033[0m')
    print(f'  {\"Request\":<25}{\"Driver\":<30}{\"Device\":<20}{\"NUMA\":<8}{\"Socket\":<10}{\"pcieRoot\":<18}{\"pciBusID\":<16}')
    print(f'  {\"─\"*25}{\"─\"*30}{\"─\"*20}{\"─\"*8}{\"─\"*10}{\"─\"*18}{\"─\"*16}')

    for d in devices:
        driver_short = d['driver']
        if len(driver_short) > 28:
            driver_short = driver_short[:28] + '..'
        print(f'  {d[\"request\"]:<25}{driver_short:<30}{d[\"device\"]:<20}{str(d[\"numa\"]):<8}{str(d[\"socketID\"]):<10}{str(d[\"pcieRoot\"]):<18}{str(d[\"pciBusID\"]):<16}')

    # Alignment summary
    numas = set(str(d['numa']) for d in devices if d['numa'] != '?')
    sockets = set(str(d['socketID']) for d in devices if d['socketID'] != '-')
    roots = set(str(d['pcieRoot']) for d in devices if d['pcieRoot'] != '-')

    print()
    if len(numas) == 1:
        print(f'  \033[32m✓ numaNode aligned: all on NUMA {numas.pop()}\033[0m')
    elif len(numas) > 1:
        numa_list = ', '.join(sorted(numas))
        print(f'  \033[33m! numaNode SPLIT: devices on NUMA {numa_list}\033[0m')
    else:
        print(f'  \033[2m? numaNode unknown\033[0m')

    if len(sockets) == 1:
        print(f'  \033[32m✓ cpuSocketID aligned: all on socket {sockets.pop()}\033[0m')
    elif len(sockets) > 1:
        socket_list = ', '.join(sorted(sockets))
        print(f'  \033[31m✗ cpuSocketID SPLIT: devices on sockets {socket_list}\033[0m')

    if len(roots) == 1:
        print(f'  \033[32m✓ pcieRoot aligned: all on {roots.pop()}\033[0m')
    elif len(roots) > 1:
        root_list = ', '.join(sorted(roots))
        print(f'  \033[33m! pcieRoot differs: {root_list} (expected on most hardware)\033[0m')

    print()
" 2>/dev/null
}

# ── cpupinning ────────────────────────────────────────────────────────────────

cmd_cpupinning() {
    section "CPU Pinning vs Device NUMA"

    local target_pod="$TARGET"
    local nf
    nf=$(ns_flag)

    if [[ -z "$target_pod" ]]; then
        echo -e "${DIM}Usage: dra-verify.sh cpupinning <pod-name> [-n namespace]${NC}"
        echo -e "${DIM}Checking all pods with DRA claims...${NC}"
        echo ""
    fi

    # Get pod cpusets and claim allocations
    kubectl get pods $nf -o json 2>/dev/null | python3 -c "
import json, sys, os, subprocess

data = json.load(sys.stdin)
target = '$target_pod'

for pod in data.get('items', []):
    name = pod['metadata']['name']
    ns = pod['metadata']['namespace']
    if target and name != target:
        continue

    # Check if pod has resource claims
    claims = pod['spec'].get('resourceClaims', [])
    if not claims:
        continue

    node = pod['spec'].get('nodeName', '?')
    uid = pod['metadata']['uid']

    print(f'\033[1m{ns}/{name}\033[0m (node: {node})')

    # Get container cpusets
    for cs in pod.get('status', {}).get('containerStatuses', []):
        cid = cs.get('containerID', '')
        cname = cs['name']

        # Try to read cpuset from cgroup (only works on the node)
        cpuset_paths = [
            f'/sys/fs/cgroup/kubepods.slice/kubepods-pod{uid.replace(\"-\", \"_\")}.slice/*/cpuset.cpus.effective',
            f'/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod{uid.replace(\"-\", \"_\")}.slice/*/cpuset.cpus.effective',
            f'/sys/fs/cgroup/kubepods.slice/kubepods-guaranteed.slice/kubepods-guaranteed-pod{uid.replace(\"-\", \"_\")}.slice/*/cpuset.cpus.effective',
        ]

        cpuset = None
        import glob
        for pattern in cpuset_paths:
            matches = glob.glob(pattern)
            for m in matches:
                if cname in m or 'compute' in m:
                    try:
                        cpuset = open(m).read().strip()
                    except:
                        pass

        if cpuset:
            print(f'  container {cname}: cpuset = {cpuset}')

            # Map CPUs to NUMA nodes
            cpu_numas = set()
            for part in cpuset.split(','):
                if '-' in part:
                    lo, hi = part.split('-')
                    cpus = range(int(lo), int(hi) + 1)
                else:
                    cpus = [int(part)]
                for cpu in cpus:
                    numa_path = f'/sys/devices/system/cpu/cpu{cpu}/topology/physical_package_id'
                    try:
                        # Check which NUMA node this CPU belongs to
                        for node_dir in glob.glob('/sys/devices/system/node/node*/cpulist'):
                            node_id = node_dir.split('node')[-1].split('/')[0]
                            cpulist = open(node_dir).read().strip()
                            for p in cpulist.split(','):
                                if '-' in p:
                                    l, h = p.split('-')
                                    if int(l) <= cpu <= int(h):
                                        cpu_numas.add(int(node_id))
                                elif int(p) == cpu:
                                    cpu_numas.add(int(node_id))
                    except:
                        pass

            if cpu_numas:
                numa_str = ', '.join(str(n) for n in sorted(cpu_numas))
                if len(cpu_numas) == 1:
                    print(f'  \033[32m✓ CPUs pinned to NUMA {numa_str}\033[0m')
                else:
                    print(f'  \033[33m! CPUs span NUMA nodes: {numa_str}\033[0m')
        else:
            print(f'  container {cname}: cpuset = \033[2m(run on node to read cgroup)\033[0m')
    print()
" 2>/dev/null
}

# ── vfio ──────────────────────────────────────────────────────────────────────

cmd_vfio() {
    section "VFIO Devices"

    echo -e "${BOLD}Devices bound to vfio-pci:${NC}"
    local found=0
    for dev in /sys/bus/pci/devices/*/driver; do
        local driver_name
        driver_name=$(basename "$(readlink "$dev" 2>/dev/null)")
        if [[ "$driver_name" == "vfio-pci" ]]; then
            local bdf
            bdf=$(basename "$(dirname "$dev")")
            local iommu_grp
            iommu_grp=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null)
            local numa
            numa=$(cat "/sys/bus/pci/devices/$bdf/numa_node" 2>/dev/null)
            local class
            class=$(cat "/sys/bus/pci/devices/$bdf/class" 2>/dev/null)
            local desc=""
            if command -v lspci &>/dev/null; then
                desc=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //')
            fi
            echo -e "  ${BOLD}$bdf${NC}  NUMA=$numa  IOMMU=$iommu_grp  ${DIM}$desc${NC}"
            found=1
        fi
    done
    if [[ "$found" == "0" ]]; then
        echo -e "  ${DIM}(no devices bound to vfio-pci — run on the node)${NC}"
    fi
    echo ""

    echo -e "${BOLD}CDI Specs (/var/run/cdi):${NC}"
    if [[ -d /var/run/cdi ]]; then
        local cdi_files
        cdi_files=$(ls /var/run/cdi/*.json 2>/dev/null)
        if [[ -n "$cdi_files" ]]; then
            for f in $cdi_files; do
                local fname
                fname=$(basename "$f")
                local devices
                devices=$(python3 -c "
import json
d = json.load(open('$f'))
devs = d.get('devices', [])
for dev in devs:
    nodes = dev.get('containerEdits', {}).get('deviceNodes', [])
    paths = [n['path'] for n in nodes if 'vfio' in n.get('path', '')]
    if paths:
        print(f'  {dev[\"name\"]}: {\", \".join(paths)}')
" 2>/dev/null)
                if [[ -n "$devices" ]]; then
                    echo -e "  ${DIM}$fname:${NC}"
                    echo "$devices"
                fi
            done
        else
            echo -e "  ${DIM}(no CDI spec files)${NC}"
        fi
    else
        echo -e "  ${DIM}(/var/run/cdi not found — run on the node)${NC}"
    fi
}

# ── metadata ──────────────────────────────────────────────────────────────────

cmd_metadata() {
    section "KEP-5304 Device Metadata"

    local target_pod="$TARGET"
    local nf
    nf=$(ns_flag)

    if [[ -z "$target_pod" ]]; then
        echo -e "${DIM}Usage: dra-verify.sh metadata <pod-name> [-n namespace]${NC}"
        echo ""
        echo -e "${DIM}Looking for pods with DRA claims...${NC}"
        kubectl get pods $nf -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pod in data.get('items', []):
    claims = pod['spec'].get('resourceClaims', [])
    if claims:
        ns = pod['metadata']['namespace']
        name = pod['metadata']['name']
        print(f'  {ns}/{name} ({len(claims)} claims)')
" 2>/dev/null
        return
    fi

    local ns_arg=""
    [[ -n "$NAMESPACE" ]] && ns_arg="-n $NAMESPACE"

    echo -e "${BOLD}Checking metadata in pod $target_pod:${NC}"
    echo ""

    # Try to list metadata files inside the pod
    kubectl exec $ns_arg "$target_pod" -- find /var/run/kubernetes.io/dra-device-attributes/ -name "*.json" 2>/dev/null | while read -r f; do
        echo -e "  ${BOLD}$f${NC}"
        kubectl exec $ns_arg "$target_pod" -- cat "$f" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for req in data.get('requests', []):
        rname = req.get('name', '?')
        for dev in req.get('devices', []):
            driver = dev.get('driver', '?')
            attrs = dev.get('attributes', {})
            pci = attrs.get('resource.kubernetes.io/pciBusID', {}).get('string', '-')
            numa = attrs.get('numaNode', {}).get('int', '-')
            model = attrs.get('productName', attrs.get('model', {})).get('string', '-')
            print(f'    request={rname} driver={driver} pciBusID={pci} numaNode={numa} model={model}')
except:
    print('    (failed to parse)')
" 2>/dev/null
        echo ""
    done

    # Also check the older path
    kubectl exec $ns_arg "$target_pod" -- find /var/run/dra-device-attributes/ -name "*.json" 2>/dev/null | while read -r f; do
        echo -e "  ${DIM}(legacy path) $f${NC}"
    done
}

# ── guest ─────────────────────────────────────────────────────────────────────

cmd_guest() {
    section "Guest NUMA Topology"

    local target_vm="$TARGET"

    if [[ -z "$target_vm" ]]; then
        echo -e "${DIM}Usage: dra-verify.sh guest <vm-name> [-n namespace]${NC}"
        echo ""
        echo -e "${DIM}Running VMs:${NC}"
        kubectl get vmi $(ns_flag) 2>/dev/null | grep -v "^NAME" || echo -e "  ${DIM}(no VMs found)${NC}"
        return
    fi

    local ns_arg=""
    [[ -n "$NAMESPACE" ]] && ns_arg="-n $NAMESPACE"

    echo -e "${BOLD}Checking guest topology for VM $target_vm:${NC}"
    echo ""

    echo -e "${BOLD}NUMA nodes:${NC}"
    virtctl ssh $ns_arg "$target_vm" -- "ls -d /sys/devices/system/node/node* 2>/dev/null | while read n; do echo \"  \$(basename \$n): \$(cat \$n/cpulist 2>/dev/null) CPUs, \$(awk '/MemTotal/{printf \"%.0f MB\", \$4/1024}' \$n/meminfo 2>/dev/null)\"; done" 2>/dev/null || echo -e "  ${DIM}(SSH failed — is virtctl available?)${NC}"
    echo ""

    echo -e "${BOLD}PCI devices with NUMA affinity:${NC}"
    virtctl ssh $ns_arg "$target_vm" -- "for d in /sys/bus/pci/devices/*/numa_node; do dev=\$(basename \$(dirname \$d)); node=\$(cat \$d); class=\$(cat /sys/bus/pci/devices/\$dev/class 2>/dev/null); [ \"\$node\" != \"-1\" ] && echo \"  \$dev: numa=\$node class=\$class\"; done" 2>/dev/null || echo -e "  ${DIM}(SSH failed)${NC}"
}

# ── slices ────────────────────────────────────────────────────────────────────

cmd_slices() {
    section "ResourceSlice Hardware Summary"

    local verbose="$VERBOSE"
    { kubectl get resourceslices -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceclaims -A -o json 2>/dev/null; } | VERBOSE="$verbose" python3 -c "
import json, sys, os
from collections import defaultdict

verbose = os.environ.get('VERBOSE', '') == '1'
raw = sys.stdin.read()
parts = raw.split('---SEP---')
data = json.loads(parts[0])
try:
    claims_data = json.loads(parts[1])
except:
    claims_data = {'items': []}

# Build set of allocated device keys: 'driver/device'
allocated = {}
for c in claims_data.get('items', []):
    reserved = c.get('status', {}).get('reservedFor', [])
    pod_name = reserved[0]['name'] if reserved else ''
    for r in c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', []):
        key = f'{r[\"driver\"]}/{r[\"device\"]}'
        allocated[key] = pod_name

# {driver: {numa: [devices]}}
by_driver = defaultdict(lambda: defaultdict(list))
nodes = set()

for rs in data.get('items', []):
    driver = rs['spec']['driver']
    node = rs['spec'].get('nodeName', rs['spec'].get('pool', {}).get('name', '?'))
    nodes.add(node)
    for dev in rs['spec'].get('devices', []) or []:
        attrs = dev.get('attributes', {})
        numa = '?'
        for key in ('resource.kubernetes.io/numaNode', 'numaNode', 'numa',
                     'dra.cpu/numaNodeID', 'dra.net/numaNode', 'dra.memory/numaNode'):
            if key in attrs:
                val = attrs[key]
                numa = str(list(val.values())[0])
                break
        pci = ''
        for key in ('resource.kubernetes.io/pciBusID', 'dra.net/pciAddress'):
            if key in attrs:
                val = attrs[key]
                pci = str(list(val.values())[0])
                break
        product = ''
        for key in ('productName', 'dra.net/pciDevice', 'model'):
            if key in attrs:
                val = attrs[key]
                product = str(list(val.values())[0])
                break
        is_vf = False
        if 'dra.net/isSriovVf' in attrs:
            is_vf = attrs['dra.net/isSriovVf'].get('bool', False)
        has_sriov = False
        if 'dra.net/sriov' in attrs:
            has_sriov = attrs['dra.net/sriov'].get('bool', False)
        num_vfs = ''
        if 'dra.net/sriovVfs' in attrs:
            num_vfs = str(list(attrs['dra.net/sriovVfs'].values())[0])
        dev_key = f'{driver}/{dev[\"name\"]}'
        by_driver[driver][numa].append({
            'name': dev['name'],
            'pci': pci,
            'product': product,
            'is_vf': is_vf,
            'has_sriov': has_sriov,
            'num_vfs': num_vfs,
            'pod': allocated.get(dev_key, ''),
        })

for node in sorted(nodes):
    print(f'\033[1mNode:\033[0m {node}')
    print()

for driver in sorted(by_driver):
    numas = by_driver[driver]
    total = sum(len(devs) for devs in numas.values())
    alloc_count = sum(1 for devs in numas.values() for d in devs if d['pod'])
    free_count = total - alloc_count
    status = f'{total} devices'
    if alloc_count > 0:
        status += f', \033[31m{alloc_count} used\033[0m, \033[32m{free_count} free\033[0m'
    print(f'\033[1m{driver}\033[0m ({status}):')
    for numa in sorted(numas):
        devs = numas[numa]
        is_cpu = 'cpu' in driver.lower()
        if is_cpu and len(devs) > 8:
            used = sum(1 for d in devs if d['pod'])
            free = len(devs) - used
            extra = ''
            if used > 0:
                extra = f' \033[31m({used} used, {free} free)\033[0m'
            print(f'  \033[2mNUMA {numa}:\033[0m {len(devs)} CPUs{extra}')
        else:
            parts = []
            for d in devs:
                label = d['name']
                if d['pci']:
                    label += f' ({d[\"pci\"]})'
                tags = []
                if d['is_vf']:
                    tags.append('VF')
                if d['has_sriov'] and d['num_vfs'] and d['num_vfs'] != '0':
                    tags.append(f'PF:{d[\"num_vfs\"]}VFs')
                elif d['has_sriov']:
                    tags.append('PF')
                if verbose and d['product']:
                    tags.append(d['product'][:35])
                if tags:
                    tag_str = ', '.join(tags)
                    label += f' \033[33m[{tag_str}]\033[0m'
                if d['pod']:
                    pod_short = d['pod'][:30]
                    label += f' \033[31m→{pod_short}\033[0m'
                parts.append(label)
            line = ', '.join(parts)
            print(f'  \033[2mNUMA {numa}:\033[0m {line}')
    print()
" 2>/dev/null
}

# ── topology ──────────────────────────────────────────────────────────────────

cmd_topology() {
    section "Device Topology Map"

    local verbose="$VERBOSE"
    kubectl get resourceslices -o json 2>/dev/null | VERBOSE="$verbose" python3 -c "
import json, sys, os
from collections import defaultdict

verbose = os.environ.get('VERBOSE', '') == '1'
data = json.load(sys.stdin)

DRIVER_LABELS = {
    'gpu.nvidia.com': 'gpu',
    'compute-domain.nvidia.com': 'compute-domain',
    'dra.cpu': 'cpu',
    'dra.memory': 'memory',
    'dra.net': 'nic',
    'dra.nvme': 'nvme',
}

devices = []
for rs in data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        attrs = dev.get('attributes', {})

        def get_attr(names):
            for n in names:
                if n in attrs:
                    v = attrs[n]
                    vals = list(v.values())
                    return str(vals[0]) if vals else '?'
            return None

        def get_bool(names):
            for n in names:
                if n in attrs:
                    v = attrs[n]
                    return v.get('bool', False)
            return False

        numa = get_attr(['resource.kubernetes.io/numaNode', 'numaNode', 'numa',
                         'dra.cpu/numaNodeID', 'dra.net/numaNode', 'dra.memory/numaNode'])
        socket = get_attr(['resource.kubernetes.io/cpuSocketID', 'cpuSocketID',
                           'dra.cpu/socketID'])
        root = get_attr(['resource.kubernetes.io/pcieRoot'])
        pci = get_attr(['resource.kubernetes.io/pciBusID', 'dra.net/pciAddress'])
        is_vf = get_bool(['dra.net/isSriovVf'])
        has_sriov = get_bool(['dra.net/sriov'])
        num_vfs = get_attr(['dra.net/sriovVfs'])
        product = get_attr(['productName', 'dra.net/pciDevice', 'dra.net/pciVendor', 'model'])

        drv_label = DRIVER_LABELS.get(driver, driver.split('.')[-1] if '.' in driver else driver)
        is_cpu = 'cpu' in driver.lower()

        devices.append({
            'name': dev['name'],
            'driver': driver,
            'label': drv_label,
            'numa': numa or '?',
            'socket': socket or '?',
            'root': root or '-',
            'pci': pci or '',
            'is_cpu': is_cpu,
            'is_vf': is_vf,
            'has_sriov': has_sriov,
            'num_vfs': num_vfs,
            'product': product or '',
        })

# ── Group by Socket → NUMA → pcieRoot ──
sockets = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
for d in devices:
    sockets[d['socket']][d['numa']][d['root']].append(d)

for sock in sorted(sockets):
    print(f'\033[1m\033[36m╔══ Socket {sock} ══╗\033[0m')
    numas = sockets[sock]
    for numa in sorted(numas):
        roots = numas[numa]
        print(f'\033[1m║ NUMA {numa}\033[0m')
        for root in sorted(roots):
            devs = roots[root]
            if root != '-':
                print(f'\033[2m║   pcieRoot: {root}\033[0m')
            by_driver = defaultdict(list)
            for d in devs:
                by_driver[d['driver']].append(d)
            for drv in sorted(by_driver):
                dlist = by_driver[drv]
                drv_label = dlist[0]['label']
                if dlist[0]['is_cpu'] and len(dlist) > 8:
                    print(f'║     {drv_label}: {len(dlist)} CPUs')
                else:
                    names = []
                    for d in dlist:
                        label = d['name']
                        if d['pci']:
                            label += f' ({d[\"pci\"]})'
                        tags = []
                        if d['is_vf']:
                            tags.append('VF')
                        if d['has_sriov'] and d['num_vfs'] and d['num_vfs'] != '0':
                            tags.append(f'PF:{d[\"num_vfs\"]}VFs')
                        elif d['has_sriov']:
                            tags.append('PF')
                        if verbose and d['product']:
                            tags.append(d['product'][:35])
                        if tags:
                            label += f' \033[33m[{\", \".join(tags)}]\033[0m'
                        names.append(label)
                    label_str = ', '.join(names)
                    print(f'║     {drv_label}: {label_str}')
        print('║')
    print(f'\033[36m╚{\"═\" * 20}╝\033[0m')
    print()
" 2>/dev/null
}

# ── deviceclasses ─────────────────────────────────────────────────────────────

cmd_deviceclasses() {
    section "Topology Coordinator Device Classes"

    local verbose="$VERBOSE"
    { kubectl get deviceclasses -l 'nodepartition.dra.k8s.io/managed=true' -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceslices -o json 2>/dev/null; } | VERBOSE="$verbose" python3 -c '
import json, sys, os, re
from collections import defaultdict

verbose = os.environ.get("VERBOSE", "") == "1"

raw = sys.stdin.read()
dc_part, slice_part = raw.split("---SEP---", 1)
dc_data = json.loads(dc_part)
slice_data = json.loads(slice_part)

items = dc_data.get("items", [])
if not items:
    print("  No topology coordinator device classes found.")
    sys.exit(0)

NUMA_ATTRS = [
    "resource.kubernetes.io/numaNode",
    "nodepartition.dra.k8s.io/numaNode",
    "dra.net/numaNode",
    "dra.cpu/numaNodeID",
    "dra.memory/numaNode",
    "dra.nvme/numaNode",
    "numaNode",
    "numa",
]

def get_numa(dev):
    """Get NUMA node from device, checking all known attribute names."""
    attrs = dev.get("attributes", {})
    for attr_name in NUMA_ATTRS:
        if attr_name in attrs:
            val = attrs[attr_name]
            if isinstance(val, dict) and "int" in val:
                return val["int"]
            if isinstance(val, (int, float)):
                return int(val)
    return None

def extract_numa_values(selectors):
    """Extract NUMA node integers from CEL selector strings."""
    numas = set()
    for sel in (selectors or []):
        for m in re.findall(r"numaNode\w*\s*==\s*(\d+)", sel):
            numas.add(int(m))
    return numas

# Build device index: driver -> numa -> [device names]
dev_by_driver_numa = defaultdict(lambda: defaultdict(list))
for s in slice_data.get("items", []):
    driver = s["spec"]["driver"]
    for d in s["spec"].get("devices", []):
        numa = get_numa(d)
        dev_by_driver_numa[driver][numa].append(d["name"])

by_profile = defaultdict(list)
for dc in items:
    labels = dc.get("metadata", {}).get("labels", {})
    profile = labels.get("nodepartition.dra.k8s.io/profile", "(unknown)")
    by_profile[profile].append(dc)

for profile in sorted(by_profile):
    print(f"\n\033[1mProfile: {profile}\033[0m")
    classes = by_profile[profile]
    order = {"eighth": 0, "quarter": 1, "half": 2, "full": 3}
    classes.sort(key=lambda dc: (
        order.get(dc["metadata"]["labels"].get("nodepartition.dra.k8s.io/partitionType", ""), 99),
        dc["metadata"]["labels"].get("nodepartition.dra.k8s.io/numa", ""),
    ))

    for dc in classes:
        labels = dc["metadata"]["labels"]
        name = dc["metadata"]["name"]
        pt = labels.get("nodepartition.dra.k8s.io/partitionType", "?")
        numa = labels.get("nodepartition.dra.k8s.io/numa", "")
        coupling = labels.get("nodepartition.dra.k8s.io/coupling", "")

        header = f"  \033[33m{pt}\033[0m"
        if numa:
            numa_display = numa.replace("_", ",").replace("numa", "")
            header += f" \033[2m\xb7\033[0m NUMA {numa_display}"
        if coupling:
            header += f" \033[2m\xb7\033[0m {coupling}"
        header += f" \033[2m→\033[0m \033[1m{name}\033[0m"
        print(header)

        configs = dc.get("spec", {}).get("config", [])
        for cfg in configs:
            opaque = cfg.get("opaque", {})
            params = opaque.get("parameters", {})
            if isinstance(params, str):
                try:
                    params = json.loads(params)
                except Exception:
                    continue
            if params.get("kind") != "PartitionConfig":
                continue

            subs = params.get("subResources", [])
            parts = []
            for sr in sorted(subs, key=lambda s: s.get("deviceClass", "")):
                drv = sr.get("deviceClass", "?")
                count = sr.get("count", 0)
                cap = sr.get("capacity", {})
                if cap:
                    cap_parts = [f"{v}" for _, v in sorted(cap.items())]
                    cap_str = ", ".join(cap_parts)
                    parts.append(f"\033[36m{drv}\033[0m: {count} ({cap_str})")
                else:
                    parts.append(f"\033[36m{drv}\033[0m: {count}")
            if parts:
                line = ", ".join(parts)
                print(f"    {line}")

            if verbose:
                for sr in sorted(subs, key=lambda s: s.get("deviceClass", "")):
                    drv = sr.get("deviceClass", "?")
                    count = sr.get("count", 0)
                    selectors = sr.get("selectors", [])
                    target_numas = extract_numa_values(selectors)

                    # Find matching devices from ResourceSlices
                    matching = []
                    if target_numas:
                        for n in sorted(target_numas):
                            matching.extend(dev_by_driver_numa[drv].get(n, []))
                    else:
                        for numa_devs in dev_by_driver_numa[drv].values():
                            matching.extend(numa_devs)

                    if drv == "dra.cpu" and len(matching) > 8:
                        print(f"    \033[2m{drv}: {len(matching)} CPUs available (need {count})\033[0m")
                    elif matching:
                        dev_list = ", ".join(sorted(matching))
                        print(f"    \033[2m{drv}: {dev_list}\033[0m")

                aligns = params.get("alignments") or []
                for a in aligns:
                    attr = a.get("attribute", "?")
                    enf = a.get("enforcement", "required")
                    reqs = a.get("requests", [])
                    req_str = f" across {len(reqs)} requests" if reqs else ""
                    print(f"    \033[32mAlignment: {attr} ({enf}{req_str})\033[0m")
    print()

total_suffix = "es" if len(items) != 1 else ""
print(f"Total: {len(items)} device class{total_suffix}")
' 2>/dev/null
}

# ── all ───────────────────────────────────────────────────────────────────────

cmd_all() {
    cmd_slices
    cmd_drivers
    cmd_attributes
    cmd_deviceclasses
    cmd_claims
    cmd_alignment
    cmd_vfio

    if [[ -n "$TARGET" ]]; then
        cmd_cpupinning
        cmd_metadata
    fi
}

# ── help ──────────────────────────────────────────────────────────────────────

cmd_help() {
    echo "Usage: $(basename "$0") <command> [options]"
    echo ""
    echo "Commands:"
    echo "  slices                     Show hardware summary from ResourceSlices"
    echo "  topology                   Show devices grouped by socket, NUMA, pcieRoot"
    echo "  drivers                    Show DRA driver DaemonSets, pods, registration"
    echo "  attributes                 Show ResourceSlice topology attributes per driver"
    echo "  deviceclasses              Show topology coordinator device classes"
    echo "  claims [-n ns]             Show allocated claims with pods/VMs and devices"
    echo "  alignment [pod] [-n ns]    Show device NUMA/pcieRoot/socket alignment"
    echo "  cpupinning [pod] [-n ns]   Show container cpuset vs device NUMA nodes"
    echo "  vfio                       Show VFIO-bound devices, IOMMU groups, CDI specs"
    echo "  metadata [pod] [-n ns]     Show KEP-5304 metadata files in pod"
    echo "  guest [vm] [-n ns]         Show guest NUMA topology in KubeVirt VM"
    echo "  all [-n ns]                Run all checks"
    echo ""
    echo "Options:"
    echo "  -n, --namespace NS         Kubernetes namespace"
    echo "  -v, --verbose              Show PCI device models (slices, topology)"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") drivers"
    echo "  $(basename "$0") alignment my-gpu-pod -n test"
    echo "  $(basename "$0") cpupinning virt-launcher-vm0-xxxxx -n default"
    echo "  $(basename "$0") metadata my-gpu-pod -n test"
    echo "  $(basename "$0") guest vm0 -n default"
    echo "  $(basename "$0") all -n test"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$CMD" in
    slices)     cmd_slices ;;
    topology)   cmd_topology ;;
    drivers)    cmd_drivers ;;
    attributes) cmd_attributes ;;
    deviceclasses) cmd_deviceclasses ;;
    claims)     cmd_claims ;;
    alignment)  cmd_alignment ;;
    cpupinning) cmd_cpupinning ;;
    vfio)       cmd_vfio ;;
    metadata)   cmd_metadata ;;
    guest)      cmd_guest ;;
    all)        cmd_all ;;
    help|-h|--help) cmd_help ;;
    *) echo "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac

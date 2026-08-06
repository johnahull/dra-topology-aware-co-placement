#!/bin/bash
# dra-verify.sh — Verify DRA topology-aware co-placement stack
#
# Usage:
#   dra-verify.sh slices                     Show hardware summary from ResourceSlices
#   dra-verify.sh topology                   Show devices grouped by pcieRoot, numaNode, cpuSocketID
#   dra-verify.sh drivers                    Show DRA driver status
#   dra-verify.sh attributes [-a]             Show ResourceSlice topology attributes (-a for all)
#   dra-verify.sh driverinfo                  Show published attributes/capacities per driver
#   dra-verify.sh deviceclasses [filter]       Show device classes (pairs|partitions|aggregates, default: all)
#   dra-verify.sh composite [-a]             Show composite device compositions (-a for all attributes)
#   dra-verify.sh claims [-n ns]             Show allocated claims with pods/VMs and devices
#   dra-verify.sh alignment [pod] [-n ns]    Show device NUMA/pcieRoot/socket alignment
#   dra-verify.sh cpupinning [pod] [-n ns]   Show cpuset vs device NUMA
#   dra-verify.sh counters                    Show KEP-4815 shared counter sets and consumption
#   dra-verify.sh vfio                       Show VFIO-bound devices and CDI specs
#   dra-verify.sh metadata [pod] [-n ns]     Show KEP-5304 metadata in pod
#   dra-verify.sh guest [vm] [-n ns]         Show guest NUMA topology in VM
#   dra-verify.sh all [-n ns]                Run all checks
#   source dra-verify.sh                    Enable bash completions
#   eval "$(dra-verify.sh completions)"     Enable bash completions (alternative)

# ── Completion function ──────────────────────────────────────────────────────
_dra_verify() {
    local cur prev cmds opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmds="slices topology drivers attributes driverinfo deviceclasses composite claims alignment cpupinning counters vfio metadata guest all help completions"
    opts="-n --namespace -v --verbose -a --all -h --help"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${cmds}" -- "${cur}") )
        return 0
    fi

    case "${prev}" in
        -n|--namespace)
            local namespaces
            namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
            COMPREPLY=( $(compgen -W "${namespaces}" -- "${cur}") )
            return 0
            ;;
        deviceclasses)
            COMPREPLY=( $(compgen -W "pairs partitions aggregates" -- "${cur}") )
            return 0
            ;;
    esac

    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    return 0
}

# If sourced (not executed), register completions and stop
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    complete -F _dra_verify dra-verify.sh
    complete -F _dra_verify dra-verify
    return 0 2>/dev/null
fi

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\x1b[1m'
DIM='\x1b[2m'
RED='\x1b[0;31m'
GREEN='\x1b[0;32m'
YELLOW='\x1b[0;33m'
CYAN='\x1b[0;36m'
MAGENTA='\x1b[0;35m'
NC='\x1b[0m'

OK="${GREEN}✓${NC}"
WARN="${YELLOW}!${NC}"
FAIL="${RED}✗${NC}"

# ── Argument parsing ──────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

NAMESPACE=""
TARGET=""
VERBOSE=""
SHOW_ALL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE="1"; shift ;;
        -a|--all) SHOW_ALL="1"; shift ;;
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
        print(f'  \x1b[1m{d}\x1b[0m: {info[\"devices\"]} devices on {nodes}')
" 2>/dev/null
    echo ""

    echo -e "${BOLD}Driver Configuration:${NC}"
    kubectl get ds -A -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)

for ds in data.get('items', []):
    name = ds['metadata']['name']
    ns = ds['metadata']['namespace']
    containers = ds['spec']['template']['spec'].get('containers', [])
    for c in containers:
        args = c.get('args', []) + c.get('command', [])
        args_str = ' '.join(args)
        # Only show DRA drivers
        if 'dra' not in args_str and 'dra' not in name and 'gpu' not in name:
            continue
        mode = None
        group_by = None
        reserved = None
        expose_pcie = None
        numa_list = None
        for a in args:
            if a.startswith('--cpu-device-mode='):
                mode = a.split('=', 1)[1]
            elif a.startswith('--group-by='):
                group_by = a.split('=', 1)[1]
            elif a.startswith('--reserved-cpus='):
                reserved = a.split('=', 1)[1]
            elif a.startswith('--expose-pcie-roots='):
                expose_pcie = a.split('=', 1)[1]
            elif a.startswith('--expose-pcie-roots'):
                expose_pcie = 'true'
            elif a.startswith('--numa-list='):
                numa_list = a.split('=', 1)[1]
        if mode or group_by or reserved or expose_pcie or numa_list:
            print(f'  \x1b[1m{ns}/{name}\x1b[0m ({c[\"name\"]}):')
            if mode:
                print(f'    cpu-device-mode = {mode}')
            if group_by:
                print(f'    group-by        = {group_by}')
            else:
                if mode == 'grouped' or (mode is None and group_by is None and any(a.startswith('--group-by') for a in args)):
                    pass
                elif mode == 'grouped' or mode is None:
                    print(f'    group-by        = \x1b[2mnumanode (default)\x1b[0m')
            if reserved:
                print(f'    reserved-cpus   = {reserved}')
            if expose_pcie:
                print(f'    expose-pcie-roots = {expose_pcie}')
            if numa_list:
                print(f'    numa-list       = {numa_list}')
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
    if [[ "$SHOW_ALL" == "1" ]]; then
        section "ResourceSlice Device Attributes (all)"
    else
        section "ResourceSlice Topology Attributes"
    fi

    kubectl get resourceslices -o json 2>/dev/null | SHOW_ALL="$SHOW_ALL" python3 -c "
import json, sys, os

show_all = os.environ.get('SHOW_ALL', '') == '1'

data = json.load(sys.stdin)
TOPO_ATTRS = [
    'resource.kubernetes.io/numaNode',
    'resource.kubernetes.io/cpuSocketID',
    'resource.kubernetes.io/pcieRoot',
    'resource.kubernetes.io/pciBusID',
]
NUMA_VENDOR = ['numaNode', 'numa', 'numaNodeID']

def extract_value(val):
    \"\"\"Extract display value from a typed attribute or capacity dict.\"\"\"
    for t in ('int', 'string', 'bool', 'ints', 'strings'):
        if t in val:
            v = val[t]
            if isinstance(v, list):
                return ','.join(str(x) for x in v)
            return v
    if 'value' in val:
        return val['value']
    if 'quantity' in val:
        return val['quantity']
    return list(val.values())[0] if val else '-'

drivers = {}
for rs in data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        name = dev['name']
        attrs = dev.get('attributes', {})
        caps = dev.get('capacity', {})

        if show_all:
            topo = {}
            for ak, av in attrs.items():
                topo[ak] = extract_value(av)
            for ck, cv in caps.items():
                key = f'{ck} [capacity]'
                topo[key] = extract_value(cv)
        else:
            topo = {}
            for key in TOPO_ATTRS:
                if key in attrs:
                    topo[key] = extract_value(attrs[key])

            topo_bare = {k.split('/')[-1] for k in topo}
            for vk in NUMA_VENDOR:
                for ak, av in attrs.items():
                    aname = ak.split('/')[-1] if '/' in ak else ak
                    if aname == vk and aname not in topo_bare:
                        topo[ak] = extract_value(av)

        if driver not in drivers:
            drivers[driver] = []
        drivers[driver].append({'name': name, 'topo': topo})

for driver in sorted(drivers):
    devs = drivers[driver]

    # Infer cpu-device-mode and group-by from device name patterns
    mode_info = ''
    if 'cpu' in driver.lower():
        names = [d['name'] for d in devs]
        has_numa = any(n.startswith('cpudevnuma') for n in names)
        has_socket = any(n.startswith('cpudevsocket') for n in names)
        has_machine = any(n == 'cpudevmachine' for n in names)
        has_individual = any(n.startswith('cpudev') and n[6:].isdigit() for n in names)
        if has_machine:
            mode_info = ' \x1b[33m[grouped/machine]\x1b[0m'
        elif has_socket:
            mode_info = ' \x1b[33m[grouped/socket]\x1b[0m'
        elif has_numa:
            mode_info = ' \x1b[33m[grouped/numanode]\x1b[0m'
        elif has_individual:
            mode_info = ' \x1b[33m[individual]\x1b[0m'

    print(f'\x1b[1m{driver}\x1b[0m ({len(devs)} devices):{mode_info}')

    all_keys = set()
    for d in devs:
        all_keys.update(d['topo'].keys())

    # Sort: topology attrs first, then remaining alphabetically
    topo_order = {a: i for i, a in enumerate(TOPO_ATTRS)}
    def sort_key(k):
        if k in topo_order:
            return (0, topo_order[k], k)
        if '[capacity]' in k:
            return (2, 0, k)
        return (1, 0, k)
    keys = sorted(all_keys, key=sort_key)

    # Short display names for columns; track legend for qualified keys
    legend = {}
    short = {}
    bare_count = {}
    for k in keys:
        bare = k.split('/')[-1] if '/' in k else k
        bare_count[bare] = bare_count.get(bare, 0) + 1
    for k in keys:
        bare = k.split('/')[-1] if '/' in k else k
        if bare_count[bare] > 1 and '/' in k:
            dom = k.split('/')[0]
            display = f'{dom.split(\".\")[0]}/{bare}'
        else:
            display = bare
        short[k] = display
        if '/' in k:
            legend[display] = k

    if not keys:
        print(f'  \x1b[2m(no attributes)\x1b[0m')
        print()
        continue

    dev_w = max(len('Device'), max((len(d['name']) for d in devs), default=6)) + 2
    col_w = {}
    for k in keys:
        vals = [str(d['topo'].get(k, '-')) for d in devs]
        col_w[k] = max(len(short[k]), max((len(v) for v in vals), default=1)) + 2

    hdr = f'  {\"Device\":<{dev_w}}'
    for k in keys:
        hdr += f'{short[k]:<{col_w[k]}}'
    print(f'\x1b[2m{hdr}\x1b[0m')

    for d in sorted(devs, key=lambda x: x['name']):
        line = f'  {d[\"name\"]:<{dev_w}}'
        for k in keys:
            v = d['topo'].get(k, '-')
            line += f'{str(v):<{col_w[k]}}'

        if not show_all:
            missing = []
            topo_bare = {tk.split('/')[-1] for tk in d['topo']}
            if 'numaNode' not in topo_bare:
                missing.append('numaNode')
            if missing:
                line += f'  \x1b[33m(missing: {\", \".join(missing)})\x1b[0m'
        print(line)

    if legend:
        parts = [f'{disp} = {full}' for disp, full in sorted(legend.items())]
        print(f'  \x1b[2m[{\", \".join(parts)}]\x1b[0m')
    print()
" 2>/dev/null
}

# ── driverinfo ────────────────────────────────────────────────────────────────

cmd_driverinfo() {
    section "DRA Driver Published Attributes"

    kubectl get resourceslices -o json 2>/dev/null | python3 -c "
import json, sys
from collections import defaultdict

data = json.load(sys.stdin)

drivers = {}
for rs in data.get('items', []):
    driver = rs['spec']['driver']
    node = rs['spec'].get('nodeName', '(cluster)')
    if driver not in drivers:
        drivers[driver] = {'slices': 0, 'devices': 0, 'nodes': set(), 'attrs': {}, 'caps': {}}
    info = drivers[driver]
    info['slices'] += 1
    info['nodes'].add(node)
    for dev in rs['spec'].get('devices', []) or []:
        info['devices'] += 1
        for ak, av in dev.get('attributes', {}).items():
            atype = next((t for t in ('int','string','bool','ints','strings') if t in av), '?')
            if ak not in info['attrs']:
                info['attrs'][ak] = {'type': atype, 'count': 0, 'sample': None}
            info['attrs'][ak]['count'] += 1
            if info['attrs'][ak]['sample'] is None:
                val = av.get(atype)
                if isinstance(val, list):
                    info['attrs'][ak]['sample'] = ','.join(str(x) for x in val)
                else:
                    info['attrs'][ak]['sample'] = str(val) if val is not None else '-'
        for ck, cv in dev.get('capacity', {}).items():
            ctype = 'quantity' if 'quantity' in cv else 'counter' if 'value' in cv else '?'
            if ck not in info['caps']:
                info['caps'][ck] = {'type': ctype, 'count': 0, 'sample': None}
            info['caps'][ck]['count'] += 1
            if info['caps'][ck]['sample'] is None:
                info['caps'][ck]['sample'] = str(cv.get('value', cv.get('quantity', '-')))

TYPE_COLORS = {
    'int': '\x1b[36m', 'string': '\x1b[32m', 'bool': '\x1b[33m',
    'ints': '\x1b[36m', 'strings': '\x1b[32m',
    'counter': '\x1b[35m', 'quantity': '\x1b[35m',
}
NC = '\x1b[0m'
DIM = '\x1b[2m'
BOLD = '\x1b[1m'

for driver in sorted(drivers):
    info = drivers[driver]
    nodes_str = ', '.join(sorted(info['nodes']))
    print(f'{BOLD}{driver}{NC}')
    print(f'  {info[\"slices\"]} slices, {info[\"devices\"]} devices on: {nodes_str}')
    print()

    std_attrs = {}
    vendor_attrs = {}
    for ak, av in info['attrs'].items():
        if 'kubernetes.io/' in ak:
            std_attrs[ak] = av
        else:
            vendor_attrs[ak] = av

    if std_attrs:
        print(f'  {BOLD}Standard attributes:{NC}')
        for ak in sorted(std_attrs):
            av = std_attrs[ak]
            tc = TYPE_COLORS.get(av['type'], '')
            coverage = f'{av[\"count\"]}/{info[\"devices\"]}'
            sample = av['sample'] or '-'
            if len(str(sample)) > 40:
                sample = str(sample)[:37] + '...'
            print(f'    {ak:<50s} {tc}{av[\"type\"]:>11s}{NC}  {DIM}{coverage:>7s}  sample: {sample}{NC}')

    if vendor_attrs:
        print(f'  {BOLD}Vendor attributes:{NC}')
        for ak in sorted(vendor_attrs):
            av = vendor_attrs[ak]
            tc = TYPE_COLORS.get(av['type'], '')
            coverage = f'{av[\"count\"]}/{info[\"devices\"]}'
            sample = av['sample'] or '-'
            if len(str(sample)) > 40:
                sample = str(sample)[:37] + '...'
            print(f'    {ak:<50s} {tc}{av[\"type\"]:>11s}{NC}  {DIM}{coverage:>7s}  sample: {sample}{NC}')

    if info['caps']:
        print(f'  {BOLD}Capacity:{NC}')
        for ck in sorted(info['caps']):
            cv = info['caps'][ck]
            tc = TYPE_COLORS.get(cv['type'], '')
            coverage = f'{cv[\"count\"]}/{info[\"devices\"]}'
            sample = cv['sample'] or '-'
            print(f'    {ck:<50s} {tc}{cv[\"type\"]:>11s}{NC}  {DIM}{coverage:>7s}  sample: {sample}{NC}')

    if not std_attrs and not vendor_attrs and not info['caps']:
        print(f'  {DIM}(no attributes published){NC}')
    print()
" 2>/dev/null
}

# ── claims ───────────────────────────────────────────────────────────────────

cmd_claims() {
    section "Allocated Resource Claims"

    local nf
    nf=$(ns_flag)

    local verbose="$VERBOSE"
    { kubectl get resourceclaims $nf -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceslices -o json 2>/dev/null; echo "---SEP---"; kubectl get vmi $nf -o json 2>/dev/null; } | VERBOSE="$verbose" python3 -c "
import json, sys, os

verbose = os.environ.get('VERBOSE', '') == '1'

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
            if short in ('numaNode', 'numa', 'numaNodeID', 'pciBusID', 'pcieRoot', 'cpuSocketID', 'productName', 'pciDevice'):
                v = list(val.values())[0]
                if short == 'pciDevice' and 'productName' not in topo:
                    topo['productName'] = v
                else:
                    topo[short] = v
        # Build productName from vendor/device attributes if not already set
        if 'productName' not in topo:
            # Also check dra.nvme/model
            for mk in ('dra.nvme/model',):
                if mk in attrs:
                    topo['productName'] = str(list(attrs[mk].values())[0])
                    break
        if 'productName' not in topo:
            _vnames = {'15b3': 'Mellanox', '1dd8': 'Pensando', '8086': 'Intel',
                       '1002': 'AMD', '10de': 'NVIDIA', '14e4': 'Broadcom'}
            _dnames = {
                '2684': 'A100', '2786': 'A100X', '2330': 'H100', '2331': 'H100',
                '2339': 'H200', '2900': 'B100', '2901': 'B200',
                '7468': 'MI355X', '75b3': 'MI355X VF', '74a1': 'MI325X',
                '740c': 'MI300X', '740f': 'MI300A',
            }
            def _vlookup(v):
                return _vnames.get(v.lower().removeprefix('0x'), v)
            def _dlookup(d):
                return _dnames.get(d.lower().removeprefix('0x'), '')
            vid = ''
            did = ''
            pfn = ''
            for vk in ('sriovnetwork.k8snetworkplumbingwg.io/vendor', 'vendorID'):
                if vk in attrs:
                    vid = attrs[vk].get('string', '')
                    break
            for dk in ('deviceID',):
                if dk in attrs:
                    did = attrs[dk].get('string', '')
                    break
            for pk in ('sriovnetwork.k8snetworkplumbingwg.io/PFName',):
                if pk in attrs:
                    pfn = attrs[pk].get('string', '')
                    break
            if vid:
                mdl = _dlookup(did) if did else ''
                label = f'{_vlookup(vid)} {mdl}'.strip() if mdl else _vlookup(vid)
                if pfn:
                    label += f' ({pfn})'
                topo['productName'] = label
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
        print(f'\x1b[2m{ns}/{cname}: pending\x1b[0m')
        continue

    # Find pod/VM
    pod_name = reserved[0]['name'] if reserved else '(unreserved)'
    vm_name = ''
    for prefix, vmi_ref in vmi_by_pod_prefix.items():
        if pod_name.startswith(prefix):
            vm_name = vmi_ref
            break

    header = f'\x1b[1m{ns}/{cname}\x1b[0m'
    if vm_name:
        header += f'  →  VM \x1b[1;35m{vm_name}\x1b[0m'
    else:
        header += f'  →  pod \x1b[1;36m{pod_name}\x1b[0m'
    print(header)

    constraints = c.get('spec', {}).get('devices', {}).get('constraints', [])
    constraint_lines = []
    if constraints:
        for con in constraints:
            ma = con.get('matchAttribute', '')
            reqs = con.get('requests', [])
            if ma:
                short_ma = ma.split('/')[-1] if '/' in ma else ma
                req_str = ', '.join(reqs) if reqs else 'all'
                enf = con.get('enforcement', '')
                enf_str = f' ({enf.lower()})' if enf else ''
                constraint_lines.append((short_ma, f'constraint: matchAttribute={short_ma} requests=[{req_str}]{enf_str}'))

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
        print(f'  \x1b[2mrequests: {req_summary_str}\x1b[0m')

    results = state.get('devices', {}).get('results', [])
    if not results:
        print('  (no devices)')
        print()
        continue

    # Constraint color map: assign a color per matchAttribute
    COLORS = {
        'pcieRoot': '\x1b[32m',   # green
        'numaNode': '\x1b[36m',   # cyan
    }
    DEFAULT_MATCH_COLOR = '\x1b[33m'  # yellow for others
    RST = '\x1b[0m'

    # Collect rows with topology data
    rows = []
    for r in results:
        driver = r['driver']
        device = r['device']
        request = r['request']
        dev_key = f'{driver}/{device}'
        topo = device_attrs.get(dev_key, {})

        numa_raw = topo.get('numaNode', topo.get('numa', topo.get('numaNodeID', '-')))
        # numaNode may be a list (physical node first) or scalar
        if isinstance(numa_raw, list):
            numa = numa_raw[0] if numa_raw else '-'
            numa_list = numa_raw
        else:
            numa = numa_raw
            numa_list = [numa_raw] if numa_raw != '-' else []
        raw_root = topo.get('pcieRoot', '-')
        pci = topo.get('pciBusID', '-')
        product = str(topo.get('productName', '-'))[:28]

        if isinstance(raw_root, list):
            root_lines = raw_root
        elif raw_root != '-':
            root_lines = [str(raw_root)]
        else:
            root_lines = ['-']

        # Consumed capacity (e.g., CPUs allocated from a consumable device)
        consumed = r.get('consumedCapacity', {})
        consumed_parts = []
        for cap_name, cap_val in consumed.items():
            short_cap = cap_name.split('/')[-1] if '/' in cap_name else cap_name
            consumed_parts.append(f'{short_cap}={cap_val}')
        consumed_str = ', '.join(consumed_parts) if consumed_parts else ''

        rows.append({'request': request, 'driver': driver, 'device': device,
                     'numa': numa, 'numa_list': numa_list, 'raw_root': raw_root,
                     'root_lines': root_lines, 'pci': pci, 'product': product,
                     'consumed': consumed_str})

    # Compute intersection per constraint attribute
    matched_constraints = {}
    for con in constraints:
        ma = con.get('matchAttribute', '')
        if not ma:
            continue
        short = ma.split('/')[-1] if '/' in ma else ma
        con_reqs = set(con.get('requests', []))

        # Map short attr name to the topo key used in device_attrs
        attr_key = short
        value_sets = []
        for row in rows:
            if con_reqs and row['request'] not in con_reqs:
                continue
            if attr_key == 'pcieRoot':
                raw = row['raw_root']
                if isinstance(raw, list):
                    value_sets.append(set(str(v) for v in raw))
                elif raw != '-':
                    value_sets.append({str(raw)})
            elif attr_key in ('numaNode',):
                # Use full numa_list for intersection matching
                nl = row.get('numa_list', [])
                if nl:
                    value_sets.append(set(str(v) for v in nl))
            else:
                continue

        if value_sets:
            common = value_sets[0]
            for s in value_sets[1:]:
                common = common & s
            if common:
                color = COLORS.get(attr_key, DEFAULT_MATCH_COLOR)
                matched_constraints[attr_key] = (common, color)

    # Print constraint lines colored by match result
    for short_ma, line in constraint_lines:
        if short_ma in matched_constraints:
            color = matched_constraints[short_ma][1]
            print(f'  {color}{line}{RST}')
        else:
            print(f'  \x1b[2m{line}\x1b[0m')

    has_consumed = any(row['consumed'] for row in rows)
    if has_consumed:
        print(f'  {\"Request\":<32}{\"Driver\":<22}{\"Device\":<24}{\"NUMA\":<6}{\"pcieRoot\":<16}{\"Consumed\":<16}{\"PCI Bus ID\":<18}{\"Product\":<30}')
        print(f'  {\"─\"*32}{\"─\"*22}{\"─\"*24}{\"─\"*6}{\"─\"*16}{\"─\"*16}{\"─\"*18}{\"─\"*30}')
    else:
        print(f'  {\"Request\":<32}{\"Driver\":<22}{\"Device\":<24}{\"NUMA\":<6}{\"pcieRoot\":<16}{\"PCI Bus ID\":<18}{\"Product\":<30}')
        print(f'  {\"─\"*32}{\"─\"*22}{\"─\"*24}{\"─\"*6}{\"─\"*16}{\"─\"*18}{\"─\"*30}')

    # Print rows with constraint-aware coloring
    for row in rows:
        request = row['request']
        request_short = request if len(request) <= 30 else request[:28] + '..'
        driver_short = row['driver'] if len(row['driver']) <= 20 else row['driver'][:18] + '..'

        # Color NUMA if numaNode constraint matched
        numa_str = str(row['numa'])
        if 'numaNode' in matched_constraints and numa_str in matched_constraints['numaNode'][0]:
            color = matched_constraints['numaNode'][1]
            numa_col = f'{color}{numa_str}{RST}' + ' ' * max(0, 6 - len(numa_str))
        else:
            numa_col = f'{numa_str:<6}'

        # Color pcieRoot if constraint matched
        first_root = row['root_lines'][0]
        if 'pcieRoot' in matched_constraints and first_root in matched_constraints['pcieRoot'][0]:
            color = matched_constraints['pcieRoot'][1]
            root_col = f'{color}{first_root}{RST}' + ' ' * max(0, 16 - len(first_root))
        else:
            root_col = f'{first_root:<16}'

        dev = row['device']
        pci_val = str(row['pci'])
        prod = row['product']
        consumed = row['consumed']
        if has_consumed:
            consumed_col = f'\x1b[33m{consumed}\x1b[0m' + ' ' * max(0, 16 - len(consumed)) if consumed else f'{\"\":<16}'
            print(f'  {request_short:<32}{driver_short:<22}{dev:<24}{numa_col}{root_col}{consumed_col}{pci_val:<18}{prod:<30}')
        else:
            print(f'  {request_short:<32}{driver_short:<22}{dev:<24}{numa_col}{root_col}{pci_val:<18}{prod:<30}')

        pad = ' ' * (32 + 22 + 24 + 6)
        for extra_root in row['root_lines'][1:]:
            if 'pcieRoot' in matched_constraints and extra_root in matched_constraints['pcieRoot'][0]:
                color = matched_constraints['pcieRoot'][1]
                print(f'  {pad}{color}{extra_root}{RST}')
            else:
                print(f'  {pad}{extra_root}')

    print()
    # Summary per constraint
    for attr_key, (common, color) in matched_constraints.items():
        val = sorted(common)[0]
        print(f'  {color}✓ {attr_key} aligned: {val}{RST}')

    # Report mismatches for constraints that didn't match
    for con in constraints:
        ma = con.get('matchAttribute', '')
        if not ma:
            continue
        short = ma.split('/')[-1] if '/' in ma else ma
        if short in matched_constraints:
            continue
        con_reqs = set(con.get('requests', []))
        if short == 'pcieRoot':
            pci_vals = []
            for row in rows:
                if con_reqs and row['request'] not in con_reqs:
                    continue
                raw = row['raw_root']
                req = row['request']
                if isinstance(raw, str) and raw != '-':
                    pci_vals.append(f'{req}={raw}')
            if pci_vals:
                mismatch_str = ', '.join(pci_vals)
                print(f'  \x1b[33m! pcieRoot mismatch: {mismatch_str}{RST}')
        elif short == 'numaNode':
            numas = set()
            for row in rows:
                if con_reqs and row['request'] not in con_reqs:
                    continue
                if row['numa'] != '-':
                    numas.add(str(row['numa']))
            if len(numas) > 1:
                numa_list = ', '.join(sorted(numas))
                print(f'  \x1b[33m! Multi-NUMA: devices on NUMA {numa_list}{RST}')
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
    print(f'\x1b[1m{pod_key}\x1b[0m')
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
        print(f'  \x1b[32m✓ numaNode aligned: all on NUMA {numas.pop()}\x1b[0m')
    elif len(numas) > 1:
        numa_list = ', '.join(sorted(numas))
        print(f'  \x1b[33m! numaNode SPLIT: devices on NUMA {numa_list}\x1b[0m')
    else:
        print(f'  \x1b[2m? numaNode unknown\x1b[0m')

    if len(sockets) == 1:
        print(f'  \x1b[32m✓ cpuSocketID aligned: all on socket {sockets.pop()}\x1b[0m')
    elif len(sockets) > 1:
        socket_list = ', '.join(sorted(sockets))
        print(f'  \x1b[31m✗ cpuSocketID SPLIT: devices on sockets {socket_list}\x1b[0m')

    if len(roots) == 1:
        print(f'  \x1b[32m✓ pcieRoot aligned: all on {roots.pop()}\x1b[0m')
    elif len(roots) > 1:
        root_list = ', '.join(sorted(roots))
        print(f'  \x1b[33m! pcieRoot differs: {root_list} (expected on most hardware)\x1b[0m')

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

    print(f'\x1b[1m{ns}/{name}\x1b[0m (node: {node})')

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
                    print(f'  \x1b[32m✓ CPUs pinned to NUMA {numa_str}\x1b[0m')
                else:
                    print(f'  \x1b[33m! CPUs span NUMA nodes: {numa_str}\x1b[0m')
        else:
            print(f'  container {cname}: cpuset = \x1b[2m(run on node to read cgroup)\x1b[0m')
    print()
" 2>/dev/null
}

# ── counters ─────────────────────────────────────────────────────────────────

cmd_counters() {
    section "KEP-4815 Shared Counter Sets"

    { kubectl get resourceslices -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceclaims -A -o json 2>/dev/null; } | python3 -c "
import json, sys
from collections import defaultdict

raw = sys.stdin.read()
parts = raw.split('---SEP---')
slices_data = json.loads(parts[0])
try:
    claims_data = json.loads(parts[1])
except:
    claims_data = {'items': []}

BOLD = '\x1b[1m'
DIM = '\x1b[2m'
GREEN = '\x1b[32m'
YELLOW = '\x1b[33m'
RED = '\x1b[31m'
CYAN = '\x1b[36m'
MAGENTA = '\x1b[35m'
NC = '\x1b[0m'

# Collect shared counter sets and devices per pool
pools = {}  # pool_name -> {counter_sets: {name: {counters}}, devices: [{name, consumesCounters}]}
for rs in slices_data.get('items', []):
    driver = rs['spec']['driver']
    pool_name = rs['spec'].get('pool', {}).get('name', '?')
    pool_key = f'{driver}/{pool_name}'
    if pool_key not in pools:
        pools[pool_key] = {'driver': driver, 'pool': pool_name, 'counter_sets': {}, 'devices': []}

    for cs in rs['spec'].get('sharedCounters', []) or []:
        cs_name = cs['name']
        counters = {}
        for cn, cv in cs.get('counters', {}).items():
            counters[cn] = cv.get('value', '?')
        pools[pool_key]['counter_sets'][cs_name] = counters

    for dev in rs['spec'].get('devices', []) or []:
        cc = dev.get('consumesCounters', []) or []
        if cc:
            pools[pool_key]['devices'].append({
                'name': dev['name'],
                'consumesCounters': cc,
                'attrs': dev.get('attributes', {}),
            })

# Build allocated device set
allocated = {}
for c in claims_data.get('items', []):
    reserved = c.get('status', {}).get('reservedFor', [])
    consumer = reserved[0]['name'] if reserved else None
    if not consumer:
        continue
    for r in c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', []):
        key = f'{r[\"driver\"]}/{r[\"device\"]}'
        allocated[key] = consumer

found = False
for pool_key in sorted(pools):
    p = pools[pool_key]
    if not p['counter_sets']:
        continue
    found = True

    print(f'{BOLD}{p[\"driver\"]}{NC} (pool: {p[\"pool\"]})')
    print()

    for cs_name in sorted(p['counter_sets']):
        counters = p['counter_sets'][cs_name]

        # Find devices consuming from this counter set
        consumers = []
        for dev in p['devices']:
            for cc in dev['consumesCounters']:
                if cc.get('counterSet') == cs_name:
                    dev_key = f'{p[\"driver\"]}/{dev[\"name\"]}'
                    is_allocated = dev_key in allocated
                    consumer_pod = allocated.get(dev_key, '')

                    consumed = {}
                    for cn, cv in cc.get('counters', {}).items():
                        consumed[cn] = cv.get('value', '?')

                    is_vf = dev.get('attrs', {}).get('isVF', {}).get('bool', None)
                    dev_type = ''
                    if is_vf is True:
                        dev_type = f' {DIM}(VF){NC}'
                    elif is_vf is False:
                        dev_type = f' {DIM}(PF){NC}'

                    consumers.append({
                        'name': dev['name'],
                        'consumed': consumed,
                        'allocated': is_allocated,
                        'pod': consumer_pod,
                        'type': dev_type,
                    })

        # Compute remaining budget per counter
        remaining = dict(counters)
        for c in consumers:
            if c['allocated']:
                for cn, cv in c['consumed'].items():
                    try:
                        r = int(remaining.get(cn, 0))
                        u = int(cv)
                        remaining[cn] = str(r - u)
                    except (ValueError, TypeError):
                        pass

        # Display counter set header
        counter_parts = []
        for cn in sorted(counters):
            total = counters[cn]
            rem = remaining.get(cn, total)
            try:
                r = int(rem)
                t = int(total)
                if r == t:
                    color = GREEN
                elif r > 0:
                    color = YELLOW
                else:
                    color = RED
                counter_parts.append(f'{cn}: {color}{rem}/{total}{NC}')
            except (ValueError, TypeError):
                counter_parts.append(f'{cn}: {rem}/{total}')
        counter_str = ', '.join(counter_parts)

        alloc_count = sum(1 for c in consumers if c['allocated'])
        free_count = len(consumers) - alloc_count
        print(f'  {CYAN}{cs_name}{NC}  [{counter_str}]')

        if not consumers:
            print(f'    {DIM}(no consuming devices){NC}')
        else:
            for c in sorted(consumers, key=lambda x: x['name']):
                consumed_str = ', '.join(f'{cn}={cv}' for cn, cv in sorted(c['consumed'].items()))
                if c['allocated']:
                    pod_str = c['pod'][:35] if c['pod'] else '?'
                    print(f'    {RED}✗{NC} {c[\"name\"]}{c[\"type\"]}  consumes [{consumed_str}]  {RED}→ {pod_str}{NC}')
                else:
                    print(f'    {GREEN}✓{NC} {c[\"name\"]}{c[\"type\"]}  consumes [{consumed_str}]  {GREEN}free{NC}')
        print()

if not found:
    print(f'  {DIM}(no KEP-4815 shared counter sets found in any ResourceSlice){NC}')
    print(f'  {DIM}Counter sets are published by DRA drivers that support partitionable devices.{NC}')
    print(f'  {DIM}Examples: NVIDIA MIG partitions, AMD SR-IOV VF/PF mutual exclusivity.{NC}')
    print()
" 2>/dev/null
}

# ── vfio ──────────────────────────────────────────────────────────────────────

cmd_vfio() {
    section "VFIO / IOMMUFD Devices"

    # IOMMU backend detection
    echo -e "${BOLD}IOMMU Backend:${NC}"
    if [[ -c /dev/iommu ]]; then
        echo -e "  ${GREEN}✓${NC} iommufd available (/dev/iommu)"
    else
        echo -e "  ${DIM}✗ iommufd not available${NC}"
    fi
    if [[ -c /dev/vfio/vfio ]]; then
        echo -e "  ${GREEN}✓${NC} VFIO container available (/dev/vfio/vfio)"
    else
        echo -e "  ${DIM}✗ VFIO container not available${NC}"
    fi
    # Check kernel config for iommufd
    local iommufd_mod=""
    if [[ -f /sys/module/iommufd/initstate ]]; then
        iommufd_mod="loaded"
    elif modinfo iommufd &>/dev/null 2>&1; then
        iommufd_mod="available (not loaded)"
    fi
    if [[ -n "$iommufd_mod" ]]; then
        echo -e "  ${DIM}iommufd module: ${iommufd_mod}${NC}"
    fi
    # Check default VFIO driver backend
    local vfio_iommu_type=""
    if [[ -f /sys/module/vfio/parameters/enable_iommufd ]]; then
        local iommufd_enabled
        iommufd_enabled=$(cat /sys/module/vfio/parameters/enable_iommufd 2>/dev/null)
        if [[ "$iommufd_enabled" == "Y" || "$iommufd_enabled" == "1" ]]; then
            vfio_iommu_type="iommufd (default)"
        else
            vfio_iommu_type="legacy container (iommufd disabled)"
        fi
    elif [[ -f /sys/module/vfio_iommu_type1/initstate ]]; then
        vfio_iommu_type="type1 (legacy)"
    fi
    if [[ -n "$vfio_iommu_type" ]]; then
        echo -e "  ${DIM}VFIO IOMMU backend: ${vfio_iommu_type}${NC}"
    fi
    echo ""

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
            # Check if this device has an iommufd or legacy vfio group device node
            local backend=""
            if [[ -c "/dev/vfio/devices/vfio${iommu_grp}" ]] || [[ -c "/dev/iommu" ]]; then
                backend=" ${DIM}[iommufd]${NC}"
            elif [[ -c "/dev/vfio/${iommu_grp}" ]]; then
                backend=" ${DIM}[legacy]${NC}"
            fi
            echo -e "  ${BOLD}$bdf${NC}  NUMA=$numa  IOMMU=$iommu_grp${backend}  ${DIM}$desc${NC}"
            found=1
        fi
    done
    if [[ "$found" == "0" ]]; then
        echo -e "  ${DIM}(no devices bound to vfio-pci — run on the node)${NC}"
    fi
    echo ""

    echo -e "${BOLD}Passthrough-Capable Devices:${NC}"
    local vf_found=0
    for dev_path in /sys/bus/pci/devices/*/; do
        local bdf
        bdf=$(basename "$dev_path")
        # Check if this is a VF (has physfn link) or has SR-IOV VFs
        local is_vf=0
        [[ -L "${dev_path}physfn" ]] && is_vf=1
        [[ "$is_vf" == "0" ]] && continue

        local driver_name="none"
        if [[ -L "${dev_path}driver" ]]; then
            driver_name=$(basename "$(readlink "${dev_path}driver")")
        fi
        local numa
        numa=$(cat "${dev_path}numa_node" 2>/dev/null || echo "?")
        local desc=""
        if command -v lspci &>/dev/null; then
            desc=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //')
        fi
        local status_color="$DIM"
        local status_label=""
        case "$driver_name" in
            vfio-pci)
                status_color="$GREEN"
                status_label="bound"
                ;;
            none|"")
                status_color="$YELLOW"
                status_label="unbound"
                driver_name="none"
                ;;
            *)
                status_color="$CYAN"
                status_label="available"
                ;;
        esac
        echo -e "  ${BOLD}$bdf${NC}  NUMA=$numa  ${status_color}${driver_name} (${status_label})${NC}  ${DIM}$desc${NC}"
        vf_found=1
    done
    if [[ "$vf_found" == "0" ]]; then
        echo -e "  ${DIM}(no VFs found — run on the node)${NC}"
    fi
    echo ""

    echo -e "${BOLD}CDI Specs (VFIO/IOMMUFD devices):${NC}"
    local found_vfio=0
    local _sudo=""
    [[ $(id -u) -ne 0 ]] && _sudo="sudo"
    for cdi_dir in /var/run/cdi /etc/cdi; do
        $_sudo test -d "$cdi_dir" 2>/dev/null || continue
        local cdi_files
        cdi_files=$($_sudo find "$cdi_dir" -maxdepth 1 \( -name '*.json' -o -name '*.yaml' \) 2>/dev/null)
        [[ -z "$cdi_files" ]] && continue
        for f in $cdi_files; do
            local fname
            fname=$(basename "$f")
            local devices
            devices=$($_sudo python3 -c "
import json, sys
try:
    import yaml
    loader = yaml
except ImportError:
    loader = None
with open('$f') as fh:
    raw = fh.read()
try:
    d = json.loads(raw)
except:
    if loader:
        d = loader.safe_load(raw)
    else:
        sys.exit(0)
if not d or not isinstance(d, dict):
    sys.exit(0)
devs = d.get('devices', [])
for dev in devs:
    nodes = dev.get('containerEdits', {}).get('deviceNodes', [])
    paths = [n['path'] for n in nodes if 'vfio' in n.get('path', '') or 'iommu' in n.get('path', '')]
    if paths:
        print(f'  {dev[\"name\"]}: {\", \".join(paths)}')
" 2>/dev/null)
            if [[ -n "$devices" ]]; then
                echo -e "  ${DIM}$cdi_dir/$fname:${NC}"
                echo "$devices"
                found_vfio=1
            fi
        done
    done
    if [[ "$found_vfio" -eq 0 ]]; then
        echo -e "  ${DIM}(no VFIO/IOMMUFD CDI specs found)${NC}"
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
            dname = dev.get('name', '?')
            attrs = dev.get('attributes', {})
            parts = []
            for k, v in sorted(attrs.items()):
                val = v.get('int', v.get('bool', v.get('string', '?')))
                parts.append(f'{k}={val}')
            attr_str = ' '.join(parts) if parts else '(none)'
            print(f'    request={rname} driver={driver} device={dname}')
            print(f'      {attr_str}')
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

    # Resolve SSH target: try virtctl ssh first, fall back to direct SSH via VMI IP
    local ssh_cmd=""
    if virtctl ssh $ns_arg --command="true" "$target_vm" &>/dev/null; then
        ssh_cmd="virtctl ssh $ns_arg $target_vm --"
    else
        local vmi_ip
        vmi_ip=$(kubectl get vmi $ns_arg "$target_vm" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
        if [[ -n "$vmi_ip" ]]; then
            ssh_cmd="sshpass -p fedora ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 fedora@$vmi_ip"
        fi
    fi

    if [[ -z "$ssh_cmd" ]]; then
        echo -e "  ${DIM}(Cannot reach VM — virtctl ssh failed and no VMI IP found)${NC}"
        return
    fi

    echo -e "${BOLD}NUMA nodes:${NC}"
    $ssh_cmd "ls -d /sys/devices/system/node/node* 2>/dev/null | while read n; do echo \"  \$(basename \$n): \$(cat \$n/cpulist 2>/dev/null) CPUs, \$(awk '/MemTotal/{printf \"%.0f MB\", \$4/1024}' \$n/meminfo 2>/dev/null)\"; done" 2>/dev/null || echo -e "  ${DIM}(SSH failed)${NC}"
    echo ""

    echo -e "${BOLD}PCI devices with NUMA affinity:${NC}"
    $ssh_cmd "for d in /sys/bus/pci/devices/*/numa_node; do dev=\$(basename \$(dirname \$d)); node=\$(cat \$d); class=\$(cat /sys/bus/pci/devices/\$dev/class 2>/dev/null); [ \"\$node\" != \"-1\" ] && echo \"  \$dev: numa=\$node class=\$class\"; done" 2>/dev/null || echo -e "  ${DIM}(SSH failed)${NC}"
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

# Build set of allocated device keys: 'driver/device' -> [pod_names]
allocated = defaultdict(list)
for c in claims_data.get('items', []):
    reserved = c.get('status', {}).get('reservedFor', [])
    pod_name = reserved[0]['name'] if reserved else ''
    if not pod_name:
        continue
    for r in c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', []):
        key = f'{r[\"driver\"]}/{r[\"device\"]}'
        allocated[key].append(pod_name)

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
        for key in ('productName', 'dra.net/pciDevice', 'dra.nvme/model', 'model'):
            if key in attrs:
                val = attrs[key]
                product = str(list(val.values())[0])
                break
        if not product:
            _vnames = {'15b3': 'Mellanox', '1dd8': 'Pensando', '8086': 'Intel',
                       '1002': 'AMD', '10de': 'NVIDIA', '14e4': 'Broadcom'}
            _dnames = {
                '2684': 'A100', '2786': 'A100X', '2330': 'H100', '2331': 'H100',
                '2339': 'H200', '2900': 'B100', '2901': 'B200',
                '7468': 'MI355X', '75b3': 'MI355X VF', '74a1': 'MI325X',
                '740c': 'MI300X', '740f': 'MI300A',
            }
            def _vlookup(v):
                return _vnames.get(v.lower().removeprefix('0x'), v)
            def _dlookup(d):
                return _dnames.get(d.lower().removeprefix('0x'), '')
            vid = ''
            did = ''
            pfn = ''
            for vk in ('sriovnetwork.k8snetworkplumbingwg.io/vendor', 'vendorID'):
                if vk in attrs:
                    vid = attrs[vk].get('string', '')
                    break
            for dk in ('deviceID',):
                if dk in attrs:
                    did = attrs[dk].get('string', '')
                    break
            for pk in ('sriovnetwork.k8snetworkplumbingwg.io/PFName',):
                if pk in attrs:
                    pfn = attrs[pk].get('string', '')
                    break
            if vid:
                model = _dlookup(did) if did else ''
                if model:
                    product = f'{_vlookup(vid)} {model}'
                else:
                    product = _vlookup(vid)
                if pfn:
                    product += f' ({pfn})'
        is_vf = False
        if 'dra.net/isSriovVf' in attrs:
            is_vf = attrs['dra.net/isSriovVf'].get('bool', False)
        elif 'sriovnetwork.k8snetworkplumbingwg.io/vfID' in attrs:
            is_vf = True
        elif 'isVF' in attrs:
            is_vf = attrs['isVF'].get('bool', False)
        has_sriov = False
        if 'dra.net/sriov' in attrs:
            has_sriov = attrs['dra.net/sriov'].get('bool', False)
        num_vfs = ''
        if 'dra.net/sriovVfs' in attrs:
            num_vfs = str(list(attrs['dra.net/sriovVfs'].values())[0])
        dev_key = f'{driver}/{dev[\"name\"]}'
        pods = allocated.get(dev_key, [])
        by_driver[driver][numa].append({
            'name': dev['name'],
            'pci': pci,
            'product': product,
            'is_vf': is_vf,
            'has_sriov': has_sriov,
            'num_vfs': num_vfs,
            'pod': pods[0] if len(pods) == 1 else '',
            'pods': pods,
        })

for node in sorted(nodes):
    print(f'\x1b[1mNode:\x1b[0m {node}')
    print()

for driver in sorted(by_driver):
    numas = by_driver[driver]
    total = sum(len(devs) for devs in numas.values())
    alloc_count = sum(1 for devs in numas.values() for d in devs if d['pods'])
    free_count = total - alloc_count
    status = f'{total} devices'
    if alloc_count > 0:
        status += f', \x1b[31m{alloc_count} used\x1b[0m, \x1b[32m{free_count} free\x1b[0m'
    print(f'\x1b[1m{driver}\x1b[0m ({status}):')
    for numa in sorted(numas):
        devs = numas[numa]
        is_cpu = 'cpu' in driver.lower()
        if is_cpu and len(devs) > 8:
            used = sum(1 for d in devs if d['pods'])
            free = len(devs) - used
            extra = ''
            if used > 0:
                extra = f' \x1b[31m({used} used, {free} free)\x1b[0m'
            print(f'  \x1b[2mNUMA {numa}:\x1b[0m {len(devs)} CPUs{extra}')
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
                if d['product'] and (verbose or d['is_vf']):
                    tags.append(d['product'][:35])
                if tags:
                    tag_str = ', '.join(tags)
                    label += f' \x1b[33m[{tag_str}]\x1b[0m'
                if d['pods']:
                    if len(d['pods']) == 1:
                        label += f' \x1b[31m→{d[\"pods\"][0][:30]}\x1b[0m'
                    else:
                        label += f' \x1b[31m→{len(d[\"pods\"])} pods\x1b[0m'
                parts.append(label)
            line = ', '.join(parts)
            print(f'  \x1b[2mNUMA {numa}:\x1b[0m {line}')
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
    'gpu.amd.com': 'gpu',
    'compute-domain.nvidia.com': 'gpu-vfio',
    'dra.cpu': 'cpu',
    'dra.memory': 'memory',
    'dra.net': 'nic',
    'dra.nvme': 'nvme',
    'sriovnetwork.k8snetworkplumbingwg.io': 'nic',
}

def parse_numa(numa_str):
    if not numa_str or numa_str == '?':
        return '?', []
    cleaned = numa_str.strip('[] ')
    parts = [p.strip() for p in cleaned.split(',') if p.strip()]
    return (parts[0], parts) if parts else ('?', [])

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

        numa_raw = get_attr(['resource.kubernetes.io/numaNode', 'numaNode', 'numa',
                         'dra.cpu/numaNodeID', 'dra.net/numaNode', 'dra.memory/numaNode'])
        socket = get_attr(['resource.kubernetes.io/cpuSocketID', 'cpuSocketID',
                           'dra.cpu/socketID'])
        root = get_attr(['resource.kubernetes.io/pcieRoot'])
        pci = get_attr(['resource.kubernetes.io/pciBusID', 'dra.net/pciAddress'])
        is_vf = get_bool(['dra.net/isSriovVf', 'isVF'])
        if not is_vf and 'sriovnetwork.k8snetworkplumbingwg.io/vfID' in attrs:
            is_vf = True
        has_sriov = get_bool(['dra.net/sriov'])
        num_vfs = get_attr(['dra.net/sriovVfs'])
        product = get_attr(['productName', 'dra.net/pciDevice', 'dra.nvme/model', 'model'])
        if not product:
            _vnames = {'15b3': 'Mellanox', '1dd8': 'Pensando', '8086': 'Intel',
                       '1002': 'AMD', '10de': 'NVIDIA', '14e4': 'Broadcom'}
            _dnames = {
                '2684': 'A100', '2786': 'A100X', '2330': 'H100', '2331': 'H100',
                '2339': 'H200', '2900': 'B100', '2901': 'B200',
                '7468': 'MI355X', '75b3': 'MI355X VF', '74a1': 'MI325X',
                '740c': 'MI300X', '740f': 'MI300A',
            }
            def _vlookup(v):
                return _vnames.get(v.lower().removeprefix('0x'), v)
            def _dlookup(d):
                return _dnames.get(d.lower().removeprefix('0x'), '')
            vid = ''
            did = ''
            pfn = ''
            for vk in ('sriovnetwork.k8snetworkplumbingwg.io/vendor', 'vendorID'):
                if vk in attrs:
                    vid = attrs[vk].get('string', '')
                    break
            for dk in ('deviceID',):
                if dk in attrs:
                    did = attrs[dk].get('string', '')
                    break
            for pk in ('sriovnetwork.k8snetworkplumbingwg.io/PFName',):
                if pk in attrs:
                    pfn = attrs[pk].get('string', '')
                    break
            if vid:
                mdl = _dlookup(did) if did else ''
                product = f'{_vlookup(vid)} {mdl}'.strip() if mdl else _vlookup(vid)
                if pfn:
                    product += f' ({pfn})'

        drv_label = DRIVER_LABELS.get(driver, driver.split('.')[-1] if '.' in driver else driver)
        is_cpu = 'cpu' in driver.lower()
        primary_numa, all_numas = parse_numa(numa_raw or '?')

        devices.append({
            'name': dev['name'],
            'driver': driver,
            'label': drv_label,
            'primary_numa': primary_numa,
            'all_numas': all_numas,
            'socket': socket,
            'root': root or '-',
            'pci': pci or '',
            'is_cpu': is_cpu,
            'is_vf': is_vf,
            'has_sriov': has_sriov,
            'num_vfs': num_vfs,
            'product': product or '',
        })

# ── Pass 2: infer socket from NUMA ──
# Step 1: collect explicit cpuSocketID mappings
numa_to_socket = {}
for d in devices:
    if d['socket'] and d['primary_numa'] != '?':
        numa_to_socket[d['primary_numa']] = d['socket']

# Step 2: if no cpuSocketID at all, derive socket from NUMA list grouping.
# Devices sharing the same set of equidistant NUMA nodes are on the same socket.
if not numa_to_socket:
    socket_groups = {}  # frozenset(all_numas) -> socket_id
    next_socket = 0
    for d in devices:
        if len(d['all_numas']) > 1:
            key = frozenset(d['all_numas'])
            if key not in socket_groups:
                socket_groups[key] = str(next_socket)
                next_socket += 1
            numa_to_socket[d['primary_numa']] = socket_groups[key]

inferred = 0
for d in devices:
    if not d['socket'] and d['primary_numa'] in numa_to_socket:
        d['socket'] = numa_to_socket[d['primary_numa']]
        inferred += 1
    elif not d['socket']:
        d['socket'] = '?'
if inferred and verbose:
    print(f'\x1b[2m(inferred socket for {inferred} devices via NUMA list grouping)\x1b[0m')

# ── Group by Socket → primary NUMA → pcieRoot ──
sockets = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
for d in devices:
    sockets[d['socket']][d['primary_numa']][d['root']].append(d)

def sock_key(s):
    try: return (0, int(s))
    except (ValueError, TypeError): return (1, s)

for sock in sorted(sockets, key=sock_key):
    print(f'\x1b[1m\x1b[36m╔══ Socket {sock} ══╗\x1b[0m')
    numas = sockets[sock]
    for numa in sorted(numas):
        roots = numas[numa]
        secondary = set()
        for root_devs in roots.values():
            for d in root_devs:
                for n in d['all_numas'][1:]:
                    secondary.add(n)
        numa_hdr = f'NUMA {numa}'
        if secondary:
            numa_hdr += f' \x1b[2m(+{chr(44).join(sorted(secondary))})\x1b[0m'
        print(f'\x1b[1m║ {numa_hdr}\x1b[0m')
        root_keys = sorted(roots)
        for ri, root in enumerate(root_keys):
            devs = roots[root]
            last_root = (ri == len(root_keys) - 1)
            if root != '-':
                branch = '└─' if last_root else '├─'
                print(f'\x1b[2m║   {branch} pcieRoot: {root}\x1b[0m')
            by_driver = defaultdict(list)
            for d in devs:
                by_driver[d['driver']].append(d)
            pipe = ' ' if last_root or root == '-' else '│'
            indent = f'║   {pipe}  ' if root != '-' else '║    '
            for drv in sorted(by_driver):
                dlist = by_driver[drv]
                drv_label = dlist[0]['label']
                if dlist[0]['is_cpu'] and len(dlist) > 8:
                    print(f'{indent} {drv_label}: {len(dlist)} CPUs')
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
                        if d['product'] and (verbose or d['is_vf']):
                            tags.append(d['product'][:35])
                        if tags:
                            label += f' \x1b[33m[{\", \".join(tags)}]\x1b[0m'
                        names.append(label)
                    label_str = ', '.join(names)
                    print(f'{indent} {drv_label}: {label_str}')
        print('║')
    print(f'\x1b[36m╚{chr(9552) * 20}╝\x1b[0m')
    print()
" 2>/dev/null
}

# ── deviceclasses ─────────────────────────────────────────────────────────────

cmd_deviceclasses() {
    section "Topology Coordinator Device Classes"

    local verbose="$VERBOSE"
    local dc_filter="${TARGET:-all}"
    { kubectl get deviceclasses -l 'nodepartition.dra.k8s.io/managed=true' -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceslices -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceclaims -A -o json 2>/dev/null; } | VERBOSE="$verbose" DC_FILTER="$dc_filter" python3 -c '
import json, sys, os, re
from collections import defaultdict

verbose = os.environ.get("VERBOSE", "") == "1"
dc_filter = os.environ.get("DC_FILTER", "all").lower()

raw = sys.stdin.read()
parts = raw.split("---SEP---")
dc_data = json.loads(parts[0])
slice_data = json.loads(parts[1])
claim_data = json.loads(parts[2])

COORD = "nodepartition.dra.k8s.io"

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

PCIE_ATTRS = [
    "resource.kubernetes.io/pcieRoot",
    "nodepartition.dra.k8s.io/pcieRoot",
    "pcieRoot",
]

def get_attr(dev, attr_list):
    attrs = dev.get("attributes", {})
    for attr_name in attr_list:
        if attr_name in attrs:
            val = attrs[attr_name]
            if isinstance(val, dict):
                return val.get("int", val.get("string"))
            return val
    return None

def get_numa(dev):
    attrs = dev.get("attributes", {})
    for attr_name in NUMA_ATTRS:
        if attr_name in attrs:
            val = attrs[attr_name]
            if isinstance(val, dict):
                if "int" in val:
                    return val["int"]
                if "ints" in val and val["ints"]:
                    return val["ints"][0]
                return val.get("string")
            return val
    return None

def get_pcie(dev):
    return get_attr(dev, PCIE_ATTRS)

def humanize_quantity(val_str):
    if not val_str:
        return val_str
    import re
    m = re.match(r"^(\d+)(Ki|Mi|Gi|Ti)?$", str(val_str))
    if not m:
        return val_str
    num = int(m.group(1))
    suffix = m.group(2) or ""
    if suffix == "Ki":
        if num >= 1024*1024:
            return f"{num/(1024*1024):.0f}Gi"
        if num >= 1024:
            return f"{num/1024:.0f}Mi"
        return f"{num}Ki"
    if suffix == "Mi":
        if num >= 1024:
            return f"{num/1024:.0f}Gi"
        return f"{num}Mi"
    return val_str

# Build device index: driver -> {name, numa, pcie}
all_devices = []
for s in slice_data.get("items", []):
    driver = s["spec"]["driver"]
    for d in s["spec"].get("devices", []):
        dev_capacity = {}
        for cap_name, cap_val in d.get("capacity", {}).items():
            if isinstance(cap_val, dict):
                dev_capacity[cap_name] = cap_val.get("value", "")
            else:
                dev_capacity[cap_name] = str(cap_val)
        all_devices.append({
            "name": d["name"],
            "driver": driver,
            "numa": get_numa(d),
            "pcie": get_pcie(d),
            "attrs": d.get("attributes", {}),
            "capacity": dev_capacity,
        })

# Build allocated device set: (driver, device_name) -> consumer name
# Also track which DeviceClass each claim used
allocated = {}
allocated_dc = {}  # (driver, device_name) -> set of DeviceClass names from the claim requests
for c in claim_data.get("items", []):
    consumers = c.get("status", {}).get("reservedFor", [])
    consumer = consumers[0]["name"] if consumers else None
    if not consumer:
        continue
    # Collect DeviceClass names from the claim requests
    claim_dcs = set()
    for req in c.get("spec", {}).get("devices", {}).get("requests", []):
        exactly = req.get("exactly", {})
        if exactly and exactly.get("deviceClassName"):
            claim_dcs.add(exactly["deviceClassName"])
    for r in c.get("status", {}).get("allocation", {}).get("devices", {}).get("results", []):
        key = (r.get("driver", ""), r.get("device", ""))
        allocated[key] = consumer
        allocated_dc[key] = claim_dcs

# Group devices by driver -> numa -> pcie_root -> [devices]
dev_tree = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
for d in all_devices:
    dev_tree[d["driver"]][d["numa"]][d["pcie"]].append(d)

def extract_numa_values(selectors):
    numas = set()
    for sel in (selectors or []):
        for m in re.findall(r"numaNode\w*\s*==\s*(\d+)", sel):
            numas.add(int(m))
        for m in re.findall(r"numaNode\w*\.includes\(\s*(\d+)\s*\)", sel):
            numas.add(int(m))
    return numas

by_profile = defaultdict(list)
by_grouping = defaultdict(list)
for dc in items:
    labels = dc.get("metadata", {}).get("labels", {})
    grouping = labels.get("nodepartition.dra.k8s.io/grouping", "")
    if grouping:
        by_grouping[grouping].append(dc)
    else:
        profile = labels.get("nodepartition.dra.k8s.io/profile", "(unknown)")
        by_profile[profile].append(dc)

show_pairs = dc_filter in ("all", "pairs", "groupings")
show_partitions = dc_filter in ("all", "partitions")
show_aggregates = dc_filter in ("all", "aggregates", "aggregate")

# Display custom groupings (pairs)
for grouping_name in sorted(by_grouping) if show_pairs else []:
    print(f"\n\x1b[1mGrouping: {grouping_name}\x1b[0m")
    classes = by_grouping[grouping_name]
    classes.sort(key=lambda dc: (
        dc["metadata"]["labels"].get("nodepartition.dra.k8s.io/alignment", ""),
        dc["metadata"]["labels"].get("nodepartition.dra.k8s.io/numa", ""),
    ))

    for dc in classes:
        labels = dc["metadata"]["labels"]
        name = dc["metadata"]["name"]
        alignment = labels.get("nodepartition.dra.k8s.io/alignment", "?")
        numa_label = labels.get("nodepartition.dra.k8s.io/numa", "")

        configs = dc.get("spec", {}).get("config", [])
        config = None
        for cfg in configs:
            opaque = cfg.get("opaque", {})
            params = opaque.get("parameters", {})
            if isinstance(params, str):
                try:
                    params = json.loads(params)
                except Exception:
                    continue
            if params.get("kind") == "PartitionConfig":
                config = params
                break

        if not config:
            continue

        subs = config.get("subResources", [])

        # Build sub-resource summary
        sub_parts = []
        for sr in subs:
            dc_name = sr.get("deviceClass", "?")
            dc_short = dc_name.split(".")[-1] if "." in dc_name else dc_name
            count = sr.get("count", 1)
            cap = sr.get("capacity", {})
            cap_str = ""
            if cap:
                cap_vals = ", ".join(str(v) for v in cap.values())
                cap_str = " (%s)" % cap_vals
            sub_parts.append("%s: %d%s" % (dc_short, count, cap_str))
        sub_summary = ", ".join(sub_parts)

        numa_str = f"NUMA {numa_label}" if numa_label else ""
        status = "\x1b[32mfree\x1b[0m"

        print(f"  {alignment} \xb7 {numa_str} → {name}  {status}")
        print(f"    {sub_summary}")

# Display partitions
for profile in sorted(by_profile) if show_partitions else []:
    print(f"\n\x1b[1mProfile: {profile}\x1b[0m")
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
        numa_label = labels.get("nodepartition.dra.k8s.io/numa", "")
        coupling = labels.get("nodepartition.dra.k8s.io/coupling", "")

        configs = dc.get("spec", {}).get("config", [])
        config = None
        for cfg in configs:
            opaque = cfg.get("opaque", {})
            params = opaque.get("parameters", {})
            if isinstance(params, str):
                try:
                    params = json.loads(params)
                except Exception:
                    continue
            if params.get("kind") == "PartitionConfig":
                config = params
                break

        if not config:
            continue

        subs = config.get("subResources", [])

        # Find target NUMA nodes from CEL selectors
        target_numas = set()
        for sr in subs:
            target_numas |= extract_numa_values(sr.get("selectors", []))

        # Reconstruct individual partition slots by grouping devices
        # by PCIe root within each target NUMA (only for sub-NUMA tiers)
        if pt in ("quarter", "eighth") and target_numas and any(sr.get("count", 0) > 0 for sr in subs):
            # Find the best driver for PCIe root grouping per NUMA.
            # Prefer GPU/accelerator, fall back to any driver with multiple PCIe roots.
            def resolve_driver(dc_name):
                if dc_name in dev_tree:
                    return dc_name
                for td in dev_tree:
                    if td in dc_name or dc_name in td:
                        return td
                return None

            def find_grouping_driver(numa_val):
                # Prefer GPU driver
                for sr in subs:
                    drv = sr.get("deviceClass", "")
                    if "gpu" in drv or "nvidia" in drv or "amd" in drv:
                        td = resolve_driver(drv)
                        if td and len(dev_tree[td].get(numa_val, {})) > 1:
                            return td
                # Fall back to any driver with multiple PCIe roots on this NUMA
                for sr in subs:
                    td = resolve_driver(sr.get("deviceClass", ""))
                    if td and len(dev_tree[td].get(numa_val, {})) > 1:
                        return td
                return None

            # Collect PCIe root groups within target NUMAs
            pcie_groups = defaultdict(lambda: defaultdict(list))
            for numa_val in sorted(target_numas):
                grp_driver = find_grouping_driver(numa_val)
                if grp_driver:
                    for pcie, devs in dev_tree[grp_driver][numa_val].items():
                        if pcie is not None:
                            for d in devs:
                                pcie_groups[numa_val][pcie].append(d)

            # If we found PCIe groups, show individual slots
            if pcie_groups:
                slot_idx = 0
                for numa_val in sorted(pcie_groups):
                    for pcie in sorted(pcie_groups[numa_val]):
                        slot_devs = pcie_groups[numa_val][pcie]
                        # Build slot header
                        header = f"  \x1b[33m{pt}\x1b[0m"
                        header += f" \x1b[2m\xb7\x1b[0m NUMA {numa_val} \x1b[2m\xb7\x1b[0m {pcie}"

                        # Check if any device in this slot is allocated
                        slot_consumer = None
                        for sd in slot_devs:
                            c = allocated.get((sd["driver"], sd["name"]))
                            if c:
                                slot_consumer = c
                                break

                        if slot_consumer:
                            header += f" \x1b[2m→\x1b[0m \x1b[1m{name}\x1b[0m"
                            header += f"  \x1b[33m⚡ {slot_consumer}\x1b[0m"
                        else:
                            header += f" \x1b[2m→\x1b[0m \x1b[1m{name}\x1b[0m"
                            header += f"  \x1b[32mfree\x1b[0m"
                        print(header)

                        # Show devices in this slot
                        slot_parts = []
                        for sr in sorted(subs, key=lambda s: s.get("deviceClass", "")):
                            drv = sr.get("deviceClass", "?")
                            count = sr.get("count", 0)
                            cap = sr.get("capacity", {})
                            # Resolve DeviceClass name to ResourceSlice driver name
                            tree_drv = drv
                            if drv not in dev_tree:
                                for td in dev_tree:
                                    if td in drv or drv in td:
                                        tree_drv = td
                                        break
                            # Show matching devices for this PCIe root
                            matching = [d["name"] for d in dev_tree[tree_drv].get(numa_val, {}).get(pcie, [])]
                            if not matching:
                                matching = [d["name"] for d in dev_tree[tree_drv].get(numa_val, {}).get(None, [])]
                            if cap:
                                cap_parts = [f"{v}" for _, v in sorted(cap.items())]
                                cap_str = ", ".join(cap_parts)
                                slot_parts.append(f"\x1b[36m{drv}\x1b[0m: {count} ({cap_str})")
                            elif matching and drv != "dra.cpu":
                                dev_str = ", ".join(sorted(matching)[:count]) if len(matching) > count else ", ".join(sorted(matching))
                                slot_parts.append(f"\x1b[36m{drv}\x1b[0m: {dev_str}")
                            else:
                                slot_parts.append(f"\x1b[36m{drv}\x1b[0m: {count}")
                        if slot_parts:
                            line = ", ".join(slot_parts)
                            print(f"    {line}")
                        slot_idx += 1
                continue

        # Fallback: show as single entry (half, full, or no PCIe subdivision)
        header = f"  \x1b[33m{pt}\x1b[0m"
        if numa_label:
            numa_display = numa_label.replace("_", ",").replace("numa", "")
            header += f" \x1b[2m\xb7\x1b[0m NUMA {numa_display}"
        if coupling:
            header += f" \x1b[2m\xb7\x1b[0m {coupling}"
        header += f" \x1b[2m→\x1b[0m \x1b[1m{name}\x1b[0m"

        # Check allocation status for this partition.
        # A partition is in-use if any device on its NUMA nodes from a
        # matching driver is allocated -- the hardware is unavailable
        # regardless of which DeviceClass name the claim used.
        partition_consumers = set()
        partition_drivers = set(sr.get("deviceClass", "") for sr in subs)
        for sr in subs:
            drv = sr.get("deviceClass", "")
            tree_drv = drv
            if drv not in dev_tree:
                for td in dev_tree:
                    if td in drv or drv in td:
                        tree_drv = td
                        break
            for numa_val in (sorted(target_numas) if target_numas else [None]):
                for pcie_key in dev_tree[tree_drv].get(numa_val, {}):
                    for d in dev_tree[tree_drv][numa_val][pcie_key]:
                        c = allocated.get((d["driver"], d["name"]))
                        if c:
                            partition_consumers.add(c)

        if partition_consumers:
            consumers_str = ", ".join(sorted(partition_consumers))
            header += f"  \x1b[33m⚡ {consumers_str}\x1b[0m"
        else:
            header += f"  \x1b[32mfree\x1b[0m"
        print(header)

        slot_parts = []
        for sr in sorted(subs, key=lambda s: s.get("deviceClass", "")):
            drv = sr.get("deviceClass", "?")
            count = sr.get("count", 0)
            cap = sr.get("capacity", {})
            if cap:
                cap_parts = [f"{v}" for _, v in sorted(cap.items())]
                cap_str = ", ".join(cap_parts)
                slot_parts.append(f"\x1b[36m{drv}\x1b[0m: {count} ({cap_str})")
            else:
                # Look up device capacity from ResourceSlice for matching devices
                tree_drv = drv
                if drv not in dev_tree:
                    for td in dev_tree:
                        if td in drv or drv in td:
                            tree_drv = td
                            break
                dev_cap_str = ""
                for numa_val in (sorted(target_numas) if target_numas else [None]):
                    for pcie_key in dev_tree.get(tree_drv, {}).get(numa_val, {}):
                        for d in dev_tree[tree_drv][numa_val][pcie_key]:
                            if d.get("capacity"):
                                cap_parts = []
                                for cn, cv in sorted(d["capacity"].items()):
                                    short_name = cn.split("/")[-1] if "/" in cn else cn
                                    cap_parts.append(f"{humanize_quantity(cv)} {short_name}")
                                dev_cap_str = ", ".join(cap_parts)
                                break
                        if dev_cap_str:
                            break
                    if dev_cap_str:
                        break
                if dev_cap_str:
                    slot_parts.append(f"\x1b[36m{drv}\x1b[0m: {count} \x1b[2m({dev_cap_str} each)\x1b[0m")
                else:
                    slot_parts.append(f"\x1b[36m{drv}\x1b[0m: {count}")
        if slot_parts:
            line = ", ".join(slot_parts)
            print(f"    {line}")

        if verbose:
            for sr in sorted(subs, key=lambda s: s.get("deviceClass", "")):
                drv = sr.get("deviceClass", "?")
                selectors = sr.get("selectors", [])
                sel_numas = extract_numa_values(selectors)
                matching = []
                if sel_numas:
                    for n in sorted(sel_numas):
                        matching.extend([d["name"] for d in dev_tree[drv].get(n, {}).get(None, [])])
                        for pcie_devs in dev_tree[drv].get(n, {}).values():
                            matching.extend([d["name"] for d in pcie_devs])
                    matching = sorted(set(matching))
                if drv == "dra.cpu" and len(matching) > 8:
                    count = sr.get("count", 0)
                    print(f"    \x1b[2m{drv}: {len(matching)} CPUs available (need {count})\x1b[0m")
                elif matching:
                    dev_str = ", ".join(matching)
                    print(f"    \x1b[2m{drv}: {dev_str}\x1b[0m")
    print()

# Build set of allocated device keys from claims
allocated_devices = set()
for c in claim_data.get("items", []):
    reserved = c.get("status", {}).get("reservedFor", [])
    if not reserved:
        continue
    for r in c.get("status", {}).get("allocation", {}).get("devices", {}).get("results", []):
        allocated_devices.add(r["driver"] + "/" + r["device"])

# Highlight aggregate DeviceClasses (no NUMA label = scheduler picks placement)
aggregates = [dc for dc in items if not dc.get("metadata", {}).get("labels", {}).get(f"{COORD}/numa")]
if aggregates and show_aggregates:
    # For each specific (per-NUMA) grouping instance, check if any of its
    # member drivers devices on that NUMA are allocated. The PartitionConfig
    # lists the driver classes; the ResourceSlices tell us which devices
    # exist on each NUMA.
    specific_items = [dc for dc in items if dc.get("metadata", {}).get("labels", {}).get(f"{COORD}/numa")]
    instances_per_group = defaultdict(int)
    allocated_per_group = defaultdict(int)
    for dc in specific_items:
        labels = dc.get("metadata", {}).get("labels", {})
        grp = labels.get(f"{COORD}/grouping", labels.get(f"{COORD}/partitionType", ""))
        numa_label = labels.get(f"{COORD}/numa", "")
        if not grp:
            continue
        instances_per_group[grp] += 1

        # Parse NUMA node IDs from the label (e.g., "numa0" -> [0], "numa0-1" -> [0,1])
        numa_ids = set()
        for part in numa_label.replace("numa", "").split("-"):
            if part.isdigit():
                numa_ids.add(int(part))

        # Check if any device from this instance on these NUMAs is allocated
        configs = dc.get("spec", {}).get("config", [])
        instance_allocated = False
        for cfg in configs:
            params = cfg.get("opaque", {}).get("parameters", {})
            if isinstance(params, str):
                try: params = json.loads(params)
                except: continue
            if params.get("kind") != "PartitionConfig":
                continue
            for sr in params.get("subResources", []):
                drv = sr.get("deviceClass", "")
                for s in slice_data.get("items", []):
                    if s["spec"]["driver"] != drv:
                        continue
                    for d in s["spec"].get("devices", []) or []:
                        dev_key = drv + "/" + d["name"]
                        if dev_key in allocated_devices:
                            attrs = d.get("attributes", {})
                            dev_numa = None
                            for nk in ["resource.kubernetes.io/numaNode", "dra.net/numaNode",
                                       "dra.cpu/numaNodeID", "dra.memory/numaNode"]:
                                if nk in attrs:
                                    v = attrs[nk]
                                    dev_numa = v.get("int")
                                    if dev_numa is None and "ints" in v and v["ints"]:
                                        dev_numa = v["ints"][0]
                                    break
                            if dev_numa is not None and int(dev_numa) in numa_ids:
                                instance_allocated = True
                                break
                    if instance_allocated:
                        break
                if instance_allocated:
                    break
            if instance_allocated:
                break
        if instance_allocated:
            allocated_per_group[grp] += 1

    print(f"\x1b[1mAggregate DeviceClasses\x1b[0m (scheduler-placed, no NUMA constraint):")
    for dc in sorted(aggregates, key=lambda x: x["metadata"]["name"]):
        name = dc["metadata"]["name"]
        labels = dc.get("metadata", {}).get("labels", {})
        pt = labels.get(f"{COORD}/partitionType", "")
        grouping = labels.get(f"{COORD}/grouping", "")
        group_key = grouping or pt

        total = instances_per_group.get(group_key, 0)
        used = allocated_per_group.get(group_key, 0)
        free = total - used

        configs = dc.get("spec", {}).get("config", [])
        sub_parts = []
        for cfg in configs:
            params = cfg.get("opaque", {}).get("parameters", {})
            if isinstance(params, str):
                try: params = json.loads(params)
                except: continue
            if params.get("kind") == "PartitionConfig":
                for sr in params.get("subResources", []):
                    drv = sr.get("deviceClass", "?")
                    count = sr.get("count", 0)
                    cap = sr.get("capacity", {})
                    if cap:
                        cap_str = ", ".join(f"{v}" for _, v in sorted(cap.items()))
                        sub_parts.append(f"{drv}: {count} ({cap_str})")
                    else:
                        sub_parts.append(f"{drv}: {count}")
                aligns = params.get("alignments") or []
                for a in aligns:
                    attr = a.get("attribute", "").split("/")[-1]
                    sub_parts.append(f"\x1b[32m🔗 {attr}\x1b[0m")

        desc = ", ".join(sub_parts) if sub_parts else ""
        label = f"\x1b[35m{pt}\x1b[0m" if pt else f"\x1b[35m{grouping}\x1b[0m"

        if total > 0:
            if used > 0:
                avail = f"\x1b[33m{free}/{total} free\x1b[0m"
            else:
                avail = f"\x1b[32m{free}/{total} free\x1b[0m"
        else:
            avail = ""

        print(f"  \x1b[1m{name}\x1b[0m  [{label}]  {avail}  {desc}")
    print()

specific = [dc for dc in items if dc.get("metadata", {}).get("labels", {}).get(f"{COORD}/numa")]
grouping_count = sum(len(v) for v in by_grouping.values())
partition_count = sum(len(v) for v in by_profile.values())
agg_count = len(aggregates)
shown = []
if show_pairs and grouping_count: shown.append(f"{grouping_count} pairs")
if show_partitions and partition_count: shown.append(f"{partition_count} partitions")
if show_aggregates and agg_count: shown.append(f"{agg_count} aggregate")
total_suffix = "es" if len(items) != 1 else ""
filter_note = f" (showing: {", ".join(shown)})" if dc_filter != "all" and shown else f" ({agg_count} aggregate, {len(specific)} specific)"
print(f"Total: {len(items)} device class{total_suffix}{filter_note}")
' 2>/dev/null
}

# ── composite ────────────────────────────────────────────────────────────────

cmd_composite() {
    section "Composite Device Compositions"

    { kubectl get resourceslices -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceclaims -A -o json 2>/dev/null; } | SHOW_ALL="$SHOW_ALL" python3 -c "
import json, sys, os
from collections import defaultdict

show_all = os.environ.get('SHOW_ALL', '') == '1'

raw = sys.stdin.read()
parts = raw.split('---SEP---')
slices_data = json.loads(parts[0])
try:
    claims_data = json.loads(parts[1])
except:
    claims_data = {'items': []}

BOLD = '\x1b[1m'
DIM = '\x1b[2m'
GREEN = '\x1b[32m'
YELLOW = '\x1b[33m'
RED = '\x1b[31m'
CYAN = '\x1b[36m'
MAGENTA = '\x1b[35m'
NC = '\x1b[0m'

def extract_value(val):
    for t in ('int', 'string', 'bool', 'ints', 'strings'):
        if t in val:
            v = val[t]
            if isinstance(v, list):
                return ','.join(str(x) for x in v)
            return v
    return '-'

# Build allocated device lookup: both composite and underlying driver devices
allocated = {}
for c in claims_data.get('items', []):
    reserved = c.get('status', {}).get('reservedFor', [])
    consumer = reserved[0]['name'] if reserved else None
    if not consumer:
        continue
    for r in c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', []):
        key = r['driver'] + '/' + r['device']
        allocated[key] = consumer

# Collect composite devices from ResourceSlices (unallocated)
# AND from claims (allocated — the composite driver removes them from the slice)
compositions = defaultdict(list)
drivers_seen = {}
seen_dev_names = set()

for rs in slices_data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        attrs = dev.get('attributes', {})
        comp_name = attrs.get('composite/compositionName', {}).get('string')
        if not comp_name:
            continue

        drivers_seen[driver] = True
        seen_dev_names.add(dev['name'])
        dev_key = driver + '/' + dev['name']
        consumer = allocated.get(dev_key, '')

        # Extract member sources and their attributes
        members = defaultdict(dict)
        top_attrs = {}
        for ak, av in attrs.items():
            if ak.startswith('composite/'):
                top_attrs[ak.split('/', 1)[1]] = extract_value(av)
            elif ak.startswith('resource.kubernetes.io/'):
                top_attrs[ak.split('/', 1)[1]] = extract_value(av)
            elif '/' in ak:
                source, attr_name = ak.split('/', 1)
                members[source][attr_name] = extract_value(av)

        compositions[(driver, comp_name)].append({
            'name': dev['name'],
            'top': top_attrs,
            'members': dict(members),
            'consumer': consumer,
        })

# Add allocated composite devices from claims (removed from ResourceSlice by driver)
for c in claims_data.get('items', []):
    results = c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', [])
    reserved = c.get('status', {}).get('reservedFor', [])
    consumer = reserved[0]['name'] if reserved else ''
    for r in results:
        driver = r['driver']
        dev_name = r['device']
        if 'composite' not in driver:
            continue
        if dev_name in seen_dev_names:
            continue
        seen_dev_names.add(dev_name)
        drivers_seen[driver] = True
        # Look up member attributes from underlying driver ResourceSlices.
        # The composite device name encodes member names: gpu-vfio-0--pci-0000-3a-00-0
        name_parts = dev_name.split('--')
        members = defaultdict(dict)
        top_attrs = {}
        for rs2 in slices_data.get('items', []):
            drv2 = rs2['spec']['driver']
            if 'composite' in drv2:
                continue
            for d2 in rs2['spec'].get('devices', []) or []:
                if d2['name'] not in name_parts:
                    continue
                attrs2 = d2.get('attributes', {})
                src = 'gpu' if 'gpu' in drv2 else 'nic' if 'net' in drv2 or 'sriov' in drv2 else drv2
                for ak, av in attrs2.items():
                    if ak.startswith('resource.kubernetes.io/'):
                        attr_name = ak.split('/', 1)[1]
                        if attr_name not in top_attrs:
                            top_attrs[attr_name] = extract_value(av)
                        members[src][attr_name] = extract_value(av)
                    else:
                        domain = ak.split('/')[0] if '/' in ak else ''
                        attr_name = ak.split('/', 1)[1] if '/' in ak else ak
                        members[src][attr_name] = extract_value(av)
        compositions[(driver, 'gpu-nic-pair')].append({
            'name': dev_name,
            'top': top_attrs,
            'members': dict(members),
            'consumer': consumer,
        })

if not compositions:
    print(f'  {DIM}(no composite devices found){NC}')
    print(f'  {DIM}Composite devices are published by composite-dra-driver.{NC}')
    print()
    sys.exit(0)

total_devices = 0
total_allocated = 0

for (driver, comp_name) in sorted(compositions):
    devs = compositions[(driver, comp_name)]
    alloc_count = sum(1 for d in devs if d['consumer'])
    free_count = len(devs) - alloc_count
    total_devices += len(devs)
    total_allocated += alloc_count

    # Discover member sources
    all_sources = set()
    for d in devs:
        all_sources.update(d['members'].keys())
    sources = sorted(all_sources)

    # Default columns: just the key identifiers per source
    DEFAULT_COLS = {
        'gpu': ['pciBusID'],
        'nic': ['ifName', 'pciVendor'],
    }

    source_display_attrs = {}
    for src in sources:
        all_attrs_for_src = set()
        for d in devs:
            for ak, av in d['members'].get(src, {}).items():
                if str(av) != '-' and av != '':
                    all_attrs_for_src.add(ak)
        all_attrs_for_src -= {'pcieRoot'}
        redundant = set()
        attr_vals = {}
        for attr in all_attrs_for_src:
            vals = tuple(str(d['members'].get(src, {}).get(attr, '-')) for d in devs)
            if vals in attr_vals.values():
                redundant.add(attr)
            else:
                attr_vals[attr] = vals
        all_attrs_for_src -= redundant

        if show_all:
            KEY_ORDER = ['pciBusID', 'pciAddr', 'pciAddress', 'ifName', 'pciVendor', 'pciDevice', 'rdma', 'mac']
            ordered = [a for a in KEY_ORDER if a in all_attrs_for_src]
            ordered += sorted(all_attrs_for_src - set(KEY_ORDER))
            source_display_attrs[src] = ordered[:6]
        else:
            defaults = DEFAULT_COLS.get(src, [])
            source_display_attrs[src] = [a for a in defaults if a in all_attrs_for_src]

    # Track which underlying member devices are consumed (from shadow claims).
    # A composite device is "unavailable" if any of its member devices is
    # allocated to another composite device (GPU shared across multiple pairs).
    consumed_members = set()  # set of member device identifiers (e.g. "gpu-vfio-2")
    for d in devs:
        if d['consumer']:
            # Extract member device names from composite device name (e.g. "gpu-vfio-0--pci-0000-3a-00-0")
            parts = d['name'].split('--')
            for p in parts:
                consumed_members.add(p)

    # Mark unavailable devices (share a consumed member but not directly allocated)
    for d in devs:
        if not d['consumer']:
            parts = d['name'].split('--')
            for p in parts:
                if p in consumed_members:
                    d['unavailable'] = True
                    break

    unavail_count = sum(1 for d in devs if not d['consumer'] and d.get('unavailable'))
    free_count = len(devs) - alloc_count - unavail_count

    status = f'{len(devs)} pairs'
    parts = []
    if alloc_count > 0:
        parts.append(f'{RED}{alloc_count} used{NC}')
    if unavail_count > 0:
        parts.append(f'{YELLOW}{unavail_count} unavailable{NC}')
    if free_count > 0:
        parts.append(f'{GREEN}{free_count} free{NC}')
    elif free_count == 0 and not parts:
        parts.append(f'{GREEN}all free{NC}')
    if parts:
        status += ', ' + ', '.join(parts)
    print(f'{BOLD}{comp_name}{NC} ({status})')
    print(f'  {DIM}driver: {driver}, members: {\" + \".join(sources)}{NC}')
    print()

    # Build table header: Device | pcieRoot | source1 cols | source2 cols | Status
    pcieRoot_w = 15
    dev_w = max(8, max((len(d['name']) for d in devs), default=8)) + 2
    if dev_w > 45:
        dev_w = 45

    # Collect columns per source
    col_info = []  # (header, width, source, attr)
    for src in sources:
        for attr in source_display_attrs[src]:
            header = f'{src}/{attr}'
            # Compute width
            vals = [str(d['members'].get(src, {}).get(attr, '-')) for d in devs]
            w = max(len(header), max((len(v) for v in vals), default=1)) + 2
            if w > 30:
                w = 30
            col_info.append((header, w, src, attr))

    # Print header
    hdr = f'  {\"Device\":<{dev_w}}{\"pcieRoot\":<{pcieRoot_w}}'
    for header, w, _, _ in col_info:
        hdr += f'{header:<{w}}'
    hdr += 'Status'
    print(f'{DIM}{hdr}{NC}')

    for d in sorted(devs, key=lambda x: x['name']):
        name = d['name']
        if len(name) > 43:
            name = name[:41] + '..'
        root = str(d['top'].get('pcieRoot', '-'))
        line = f'  {name:<{dev_w}}{root:<{pcieRoot_w}}'
        for _, w, src, attr in col_info:
            val = str(d['members'].get(src, {}).get(attr, '-'))
            if len(val) > w - 2:
                val = val[:w-4] + '..'
            line += f'{val:<{w}}'
        if d['consumer']:
            pod = d['consumer'][:30]
            line += f'{RED}{pod}{NC}'
        elif d.get('unavailable'):
            line += f'{YELLOW}unavailable{NC}'
        else:
            line += f'{GREEN}free{NC}'
        print(line)

    print()

# Summary
driver_list = ', '.join(sorted(drivers_seen))
print(f'{DIM}{len(compositions)} composition(s), {total_devices} total devices, {total_allocated} allocated{NC}')
print(f'{DIM}driver(s): {driver_list}{NC}')
print()
" 2>/dev/null
}

# ── all ───────────────────────────────────────────────────────────────────────

cmd_all() {
    cmd_slices
    cmd_drivers
    cmd_attributes
    cmd_deviceclasses
    cmd_composite
    cmd_claims
    cmd_alignment
    cmd_counters
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
    echo "  attributes [-a]            Show ResourceSlice topology attributes (-a for all)"
    echo "  driverinfo                 Show published attributes/capacities per driver"
    echo "  deviceclasses [filter]     Show device classes (pairs|partitions|aggregates, default: all)"
    echo "  composite [-a]             Show composite device compositions (-a for all attributes)"
    echo "  claims [-n ns]             Show allocated claims with pods/VMs and devices"
    echo "  alignment [pod] [-n ns]    Show device NUMA/pcieRoot/socket alignment"
    echo "  cpupinning [pod] [-n ns]   Show container cpuset vs device NUMA nodes"
    echo "  counters                   Show KEP-4815 shared counter sets and consumption"
    echo "  vfio                       Show VFIO-bound devices, IOMMU groups, CDI specs"
    echo "  metadata [pod] [-n ns]     Show KEP-5304 metadata files in pod"
    echo "  guest [vm] [-n ns]         Show guest NUMA topology in KubeVirt VM"
    echo "  all [-n ns]                Run all checks"
    echo "  completions                Output bash completion script"
    echo ""
    echo "Options:"
    echo "  -n, --namespace NS         Kubernetes namespace"
    echo "  -a, --all                  Show all attributes and capacities (attributes)"
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

# ── Completions ───────────────────────────────────────────────────────────────

cmd_completions() {
    declare -f _dra_verify
    echo 'complete -F _dra_verify dra-verify.sh'
    echo 'complete -F _dra_verify dra-verify'
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$CMD" in
    slices)     cmd_slices ;;
    topology)   cmd_topology ;;
    drivers)    cmd_drivers ;;
    attributes) cmd_attributes ;;
    driverinfo) cmd_driverinfo ;;
    deviceclasses) cmd_deviceclasses ;;
    composite)  cmd_composite ;;
    claims)     cmd_claims ;;
    alignment)  cmd_alignment ;;
    cpupinning) cmd_cpupinning ;;
    counters)   cmd_counters ;;
    vfio)       cmd_vfio ;;
    metadata)   cmd_metadata ;;
    guest)      cmd_guest ;;
    all)        cmd_all ;;
    help|-h|--help) cmd_help ;;
    completions|--completions) cmd_completions ;;
    *) echo "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac

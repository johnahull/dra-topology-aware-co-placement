#!/bin/bash
# show-dra-topology.sh — Show DRA device allocation and NUMA topology
#
# Usage:
#   ./show-dra-topology.sh                    # all claims in all namespaces
#   ./show-dra-topology.sh -n test            # all claims in namespace "test"
#   ./show-dra-topology.sh -n test half0      # specific claim
#   ./show-dra-topology.sh --drivers          # show all DRA drivers and devices
#   ./show-dra-topology.sh --summary          # one-line-per-pod summary

set -euo pipefail

NAMESPACE=""
CLAIM=""
MODE="claims"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --drivers) MODE="drivers"; shift ;;
    --summary) MODE="summary"; shift ;;
    -h|--help)
      echo "Usage: $0 [-n namespace] [claim-name] [--drivers] [--summary]"
      exit 0 ;;
    *) CLAIM="$1"; shift ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

show_drivers() {
  echo -e "${BOLD}=== DRA Drivers ===${NC}"
  kubectl get resourceslices -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
drivers = {}
for rs in data['items']:
    driver = rs['spec']['driver']
    devices = rs['spec'].get('devices', []) or []
    if driver not in drivers:
        drivers[driver] = []
    for dev in devices:
        attrs = dev.get('attributes', {})
        numa = None
        for k, v in attrs.items():
            if 'numa' in k.lower():
                numa = list(v.values())[0]
                break
        pci = None
        for k in ['resource.kubernetes.io/pciBusID', 'pciAddr']:
            if k in attrs:
                pci = list(attrs[k].values())[0]
                break
        drivers[driver].append({
            'name': dev['name'],
            'numa': numa,
            'pci': pci
        })

for driver in sorted(drivers):
    devs = drivers[driver]
    numa0 = [d for d in devs if d['numa'] == 0]
    numa1 = [d for d in devs if d['numa'] == 1]
    other = [d for d in devs if d['numa'] not in (0, 1)]
    print(f'\n  {driver}: {len(devs)} devices')
    if numa0:
        names = ', '.join(d['name'] for d in numa0)
        print(f'    NUMA 0: {names}')
    if numa1:
        names = ', '.join(d['name'] for d in numa1)
        print(f'    NUMA 1: {names}')
    if other:
        names = ', '.join(d['name'] for d in other)
        print(f'    NUMA ?: {names}')
"
  echo
}

show_claim() {
  local ns="$1"
  local name="$2"

  kubectl get resourceclaim "$name" -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys

c = json.load(sys.stdin)
alloc = c.get('status', {}).get('allocation', {})
results = alloc.get('devices', {}).get('results', [])

if not results:
    print(f'  (not allocated)')
    sys.exit(0)

# Group by request
by_request = {}
for r in results:
    req = r['request']
    if req not in by_request:
        by_request[req] = []
    by_request[req].append(r)

for req in sorted(by_request):
    devices = by_request[req]
    driver = devices[0]['driver']
    names = ', '.join(d['device'] for d in devices)
    print(f'  {req} ({driver}): {names}')
"
}

show_claims() {
  local ns_flag=""
  [[ -n "$NAMESPACE" ]] && ns_flag="-n $NAMESPACE" || ns_flag="-A"

  if [[ -n "$CLAIM" ]]; then
    echo -e "${BOLD}=== $CLAIM ($NAMESPACE) ===${NC}"
    show_claim "$NAMESPACE" "$CLAIM"
    return
  fi

  # Get all claims with their reserved pods
  kubectl get resourceclaims $ns_flag -o json 2>/dev/null | python3 -c "
import json, sys

data = json.load(sys.stdin)
claims = data.get('items', [])

if not claims:
    print('No resource claims found.')
    sys.exit(0)

# Group claims by pod
pods = {}
unclaimed = []

for c in claims:
    ns = c['metadata']['namespace']
    name = c['metadata']['name']
    alloc = c.get('status', {}).get('allocation', {})
    results = alloc.get('devices', {}).get('results', [])
    reserved = c.get('status', {}).get('reservedFor', [])

    pod_name = reserved[0]['name'] if reserved else None

    entry = {
        'claim': name,
        'namespace': ns,
        'results': results
    }

    if pod_name:
        key = f'{ns}/{pod_name}'
        if key not in pods:
            pods[key] = {'devices': {}, 'numa_nodes': set()}
        for r in results:
            req = r['request']
            driver = r['driver']
            device = r['device']
            if driver not in pods[key]['devices']:
                pods[key]['devices'][driver] = []
            pods[key]['devices'][driver].append(device)
    else:
        unclaimed.append(entry)

# Print per-pod topology
for pod_key in sorted(pods):
    ns, pod = pod_key.split('/', 1)
    info = pods[pod_key]
    print(f'\033[1m=== {pod} ({ns}) ===\033[0m')

    for driver in sorted(info['devices']):
        devices = info['devices'][driver]
        # Shorten driver name
        short = driver.split('/')[-1]
        if '.' in short:
            parts = short.split('.')
            short = parts[0] if len(parts[0]) > 3 else '.'.join(parts[:2])

        print(f'  {driver}:')
        for d in sorted(devices):
            print(f'    {d}')
    print()

if unclaimed:
    print('\033[1m=== Unbound Claims ===\033[0m')
    for entry in unclaimed:
        state = 'allocated' if entry['results'] else 'pending'
        print(f'  {entry[\"namespace\"]}/{entry[\"claim\"]}: {state}')
"
}

show_summary() {
  local ns_flag=""
  [[ -n "$NAMESPACE" ]] && ns_flag="-n $NAMESPACE" || ns_flag="-A"

  echo -e "${BOLD}Pod                    NUMA  CPUs  GPUs  NICs  Memory${NC}"
  echo    "-----                  ----  ----  ----  ----  ------"

  kubectl get resourceclaims $ns_flag -o json 2>/dev/null | python3 -c "
import json, sys

data = json.load(sys.stdin)
pods = {}

for c in data.get('items', []):
    reserved = c.get('status', {}).get('reservedFor', [])
    if not reserved:
        continue
    pod = reserved[0]['name']
    ns = c['metadata']['namespace']
    key = f'{ns}/{pod}'
    if key not in pods:
        pods[key] = {'cpu': [], 'gpu': [], 'nic': [], 'mem': [], 'numa': set()}

    for r in c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', []):
        driver = r['driver']
        device = r['device']
        if 'cpu' in driver:
            pods[key]['cpu'].append(device)
            # Extract NUMA from device name
            if 'numa000' in device: pods[key]['numa'].add(0)
            elif 'numa001' in device: pods[key]['numa'].add(1)
        elif 'gpu' in driver:
            pods[key]['gpu'].append(device)
        elif 'sriov' in driver:
            pods[key]['nic'].append(device)
        elif 'memory' in driver:
            pods[key]['mem'].append(device)

for key in sorted(pods):
    p = pods[key]
    ns, pod = key.split('/', 1)
    numa = ','.join(str(n) for n in sorted(p['numa'])) if p['numa'] else '?'
    # Pad for alignment
    name = f'{pod}'
    print(f'{name:<23}{numa:<6}{len(p[\"cpu\"]):<6}{len(p[\"gpu\"]):<6}{len(p[\"nic\"]):<6}{len(p[\"mem\"])}')
"
}

case "$MODE" in
  drivers) show_drivers ;;
  summary) show_summary ;;
  claims)  show_claims ;;
esac

#!/usr/bin/env python3
"""Render and validate DRA shared counter publication and allocation state."""

import json
import re
import sys
from collections import defaultdict


COLORS = {
    "bold": "\033[1m", "dim": "\033[2m", "green": "\033[32m",
    "yellow": "\033[33m", "red": "\033[31m", "cyan": "\033[36m",
    "reset": "\033[0m",
}


def color(name, value):
    return f"{COLORS[name]}{value}{COLORS['reset']}"


def attr_value(attrs, names):
    for name in names:
        value = attrs.get(name)
        if isinstance(value, dict):
            for key in ("string", "int", "bool"):
                if key in value:
                    return str(value[key]).lower()
    return None


def pci_identity(attrs):
    return attr_value(attrs, (
        "resource.kubernetes.io/pciBusID", "dra.net/pciAddress", "pciAddr",
        "pciAddress", "pciBusID",
    ))


def pool_name(resource_slice):
    return resource_slice.get("spec", {}).get("pool", {}).get("name", "?")


def build_model(slices_data, claims_data):
    pools = {}
    devices_by_key = {}
    devices_by_identity = defaultdict(list)
    diagnostics = []

    for resource_slice in slices_data.get("items", []):
        spec = resource_slice.get("spec", {})
        driver = spec.get("driver", "?")
        pool = pool_name(resource_slice)
        pool_key = f"{driver}/{pool}"
        entry = pools.setdefault(pool_key, {
            "driver": driver, "pool": pool, "counter_sets": {},
            "devices": [], "unresolved": [],
        })

        for counter_set in spec.get("sharedCounters", []) or []:
            name = counter_set.get("name", "?")
            counters = {
                key: value.get("value", "?")
                for key, value in (counter_set.get("counters", {}) or {}).items()
            }
            if name in entry["counter_sets"]:
                diagnostics.append(f"duplicate counter set {driver}/{pool}/{name}")
            entry["counter_sets"][name] = counters

        for device in spec.get("devices", []) or []:
            name = device.get("name", "?")
            consumes = device.get("consumesCounters", []) or []
            attrs = device.get("attributes", {}) or {}
            model_device = {
                "name": name, "consumesCounters": consumes, "attrs": attrs,
                "pool_key": pool_key, "pci": pci_identity(attrs),
            }
            key = f"{driver}/{name}"
            if key in devices_by_key:
                diagnostics.append(f"duplicate device {key}")
            devices_by_key[key] = model_device
            if not consumes:
                continue
            entry["devices"].append(model_device)
            if model_device["pci"]:
                devices_by_identity[(driver, model_device["pci"])].append(model_device)

    for pool in pools.values():
        for device in pool["devices"]:
            for consumption in device["consumesCounters"]:
                counter_set = consumption.get("counterSet")
                if counter_set not in pool["counter_sets"]:
                    diagnostics.append(
                        f"device {pool['driver']}/{device['name']} references missing counter set {counter_set}"
                    )
                    continue
                for counter_name in (consumption.get("counters", {}) or {}):
                    if counter_name not in pool["counter_sets"][counter_set]:
                        diagnostics.append(
                            f"device {pool['driver']}/{device['name']} references missing counter {counter_name} in {counter_set}"
                        )

    allocations = defaultdict(list)
    for claim in claims_data.get("items", []):
        metadata = claim.get("metadata", {})
        namespace = metadata.get("namespace", "default")
        claim_name = metadata.get("name", "?")
        reserved = claim.get("status", {}).get("reservedFor", []) or []
        consumers = [
            f"{item.get('namespace', namespace)}/{item.get('name', '?')}"
            for item in reserved
        ]
        if not consumers:
            continue
        for result in claim.get("status", {}).get("allocation", {}).get("devices", {}).get("results", []) or []:
            driver = result.get("driver", "?")
            name = result.get("device", "?")
            key = f"{driver}/{name}"
            allocations[key].append({
                "consumer": ",".join(consumers), "claim": f"{namespace}/{claim_name}",
            })

    # Resolve direct allocations and sibling devices sharing the same stable PCI identity.
    resolved = {}
    unresolved_by_pool = defaultdict(list)
    for key, owners in allocations.items():
        direct = devices_by_key.get(key)
        targets = []
        if direct:
            targets = [direct]
            if direct["pci"]:
                targets = devices_by_identity.get((key.split("/", 1)[0], direct["pci"]), [direct])
        else:
            unresolved_by_pool[key.split("/", 1)[0]].append(key)
            continue
        for target in targets:
            resolved.setdefault(f"{target['pool_key']}/{target['name']}", []).extend(
                {**owner, "via_pci": target["name"] != name} for owner in owners
            )

    for pool_key, unknown in unresolved_by_pool.items():
        driver = pool_key.split("/", 1)[0]
        for candidate_key, pool in pools.items():
            if candidate_key.split("/", 1)[0] == driver:
                pool["unresolved"].extend(unknown)

    return pools, resolved, diagnostics


def numeric(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"[+-]?\d+", value.strip()):
        return int(value.strip())
    return None


def render(slices_data, claims_data, out=None):
    out = out or sys.stdout
    pools, resolved, diagnostics = build_model(slices_data, claims_data)
    found = False

    for pool_key in sorted(pools):
        pool = pools[pool_key]
        if not pool["counter_sets"]:
            continue
        found = True
        print(f"{color('bold', pool['driver'])} (pool: {pool['pool']})", file=out)
        print(file=out)

        for counter_name in sorted(pool["counter_sets"]):
            counters = pool["counter_sets"][counter_name]
            consumers = []
            for device in pool["devices"]:
                for consumption in device["consumesCounters"]:
                    if consumption.get("counterSet") != counter_name:
                        continue
                    consumed = {
                        key: value.get("value", "?")
                        for key, value in (consumption.get("counters", {}) or {}).items()
                    }
                    resolved_key = f"{pool_key}/{device['name']}"
                    owners = resolved.get(resolved_key, [])
                    is_vf = attr_value(device["attrs"], ("isVF",))
                    device_type = ""
                    if is_vf == "true":
                        device_type = f" {color('dim', '(VF)')}"
                    elif is_vf == "false":
                        device_type = f" {color('dim', '(PF)')}"
                    consumers.append({
                        "name": device["name"], "consumed": consumed,
                        "owners": owners, "type": device_type,
                    })

            remaining = dict(counters)
            uncertain = bool(pool["unresolved"])
            for consumer in consumers:
                if not consumer["owners"]:
                    continue
                for name, value in consumer["consumed"].items():
                    total = numeric(remaining.get(name))
                    used = numeric(value)
                    if total is None or used is None:
                        uncertain = True
                        continue
                    remaining[name] = str(total - used)

            parts = []
            for name in sorted(counters):
                total = counters[name]
                rem = remaining.get(name, total)
                if uncertain:
                    parts.append(f"{name}: {color('yellow', '?')}/{total}")
                    continue
                r, t = numeric(rem), numeric(total)
                if r is None or t is None:
                    parts.append(f"{name}: {rem}/{total}")
                else:
                    shade = "green" if r == t else "yellow" if r > 0 else "red"
                    parts.append(f"{name}: {color(shade, f'{rem}/{total}')}")
            print(f"  {color('cyan', counter_name)}  [{', '.join(parts)}]", file=out)

            if not consumers:
                print(f"    {color('dim', '(no consuming devices)')}", file=out)
            for consumer in sorted(consumers, key=lambda item: item["name"]):
                consumed = ", ".join(
                    f"{name}={value}" for name, value in sorted(consumer["consumed"].items())
                )
                if consumer["owners"]:
                    owner = consumer["owners"][0]["consumer"][:35]
                    suffix = " (PCI identity)" if any(
                        owner_info.get("via_pci") for owner_info in consumer["owners"]
                    ) else ""
                    print(f"    {color('red', '✗')} {consumer['name']}{consumer['type']}  consumes [{consumed}]  {color('red', '→ ' + owner + suffix)}", file=out)
                else:
                    state = "available; allocation correlation incomplete" if uncertain else "available"
                    print(f"    {color('green', '✓')} {consumer['name']}{consumer['type']}  consumes [{consumed}]  {color('green', state)}", file=out)
            print(file=out)

        if pool["unresolved"]:
            print(f"  {color('yellow', 'Unresolved allocations:')} {', '.join(sorted(pool['unresolved']))}", file=out)
            print(f"  {color('dim', 'Counter totals are indeterminate because allocation results do not identify a published counter device.')}", file=out)
            print(file=out)

    if diagnostics:
        print(f"{color('yellow', 'Diagnostics:')}", file=out)
        for diagnostic in sorted(set(diagnostics)):
            print(f"  {color('yellow', '!')} {diagnostic}", file=out)
        print(file=out)

    if not found:
        print(f"  {color('dim', '(no KEP-4815 shared counter sets found in any ResourceSlice)')}", file=out)
        print(f"  {color('dim', 'Counter sets are published by DRA drivers that support partitionable devices.')}", file=out)
        print(file=out)


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} RESOURCESLICES.json RESOURCECLAIMS.json", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as stream:
            slices = json.load(stream)
        with open(sys.argv[2], encoding="utf-8") as stream:
            claims = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        print(f"dra-verify counters: unable to read Kubernetes JSON: {error}", file=sys.stderr)
        return 1
    render(slices, claims)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

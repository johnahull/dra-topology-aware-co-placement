#!/bin/bash
# numa-topology.sh — Display NUMA nodes with CPUs and PCIe device topology tree

set -uo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────
PCIE_ONLY=0
NO_DIMM=0
FLAT=0

# Device class filters (additive — if none set, show all)
declare -A CLASS_FILTER=()

for arg in "$@"; do
    case "$arg" in
        -p|--pcie)          PCIE_ONLY=1 ;;
        -f|--flat)          FLAT=1 ;;
        --no-dimm)          NO_DIMM=1 ;;
        -a|--accelerators)  CLASS_FILTER[18]=1 ;;   # 0x12 = Processing accelerator
        -n|--network)       CLASS_FILTER[2]=1 ;;    # 0x02 = Network
        -s|--storage)       CLASS_FILTER[1]=1 ;;    # 0x01 = Storage
        -d|--display)       CLASS_FILTER[3]=1 ;;    # 0x03 = Display/GPU
        -u|--usb)           CLASS_FILTER[12]=1 ;;   # 0x0C = Serial bus (USB/TB)
        -m|--multimedia)    CLASS_FILTER[4]=1 ;;    # 0x04 = Multimedia
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo ""
            echo "Layout options:"
            echo "  -p, --pcie          Show only devices with an active PCIe link (skip on-die devices)"
            echo "  -f, --flat          List endpoint devices only, no bus/bridge hierarchy"
            echo "  --no-dimm           Skip DIMM info (no dmidecode; faster for non-root users)"
            echo ""
            echo "Device class filters (additive — combine to show multiple categories):"
            echo "  -a, --accelerators  Processing accelerators (GPUs, NPUs — class 0x12)"
            echo "  -n, --network       Network controllers (NICs — class 0x02)"
            echo "  -s, --storage       Storage controllers (NVMe, SATA — class 0x01)"
            echo "  -d, --display       Display/VGA controllers (class 0x03)"
            echo "  -u, --usb           Serial bus controllers (USB, Thunderbolt — class 0x0C)"
            echo "  -m, --multimedia    Multimedia devices (audio, video — class 0x04)"
            echo ""
            echo "Examples:"
            echo "  $(basename "$0") -a -n          Show only accelerators and NICs"
            echo "  $(basename "$0") -s --flat      Show storage devices in flat list"
            echo "  $(basename "$0") -n -p          Show NICs with active PCIe links only"
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

FILTER_ACTIVE=$(( ${#CLASS_FILTER[@]} > 0 ? 1 : 0 ))

# Check if a device class matches the active filters
# Returns 0 (true) if device should be shown
class_matches_filter() {
    local class_hex="$1"
    [ "$FILTER_ACTIVE" = "0" ] && return 0  # no filter = show all
    local class_int
    class_int=$(printf '%d' "$class_hex" 2>/dev/null) || return 1
    local top=$(( class_int >> 16 ))
    [ -n "${CLASS_FILTER[$top]+x}" ] && return 0
    return 1
}

# Colors
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
WHITE='\033[0;37m'
RESET='\033[0m'

# ── DIMM data (parsed once from dmidecode if available) ───────────────────────

declare -A DIMM_DATA=()       # "ARRAY_IDX:SLOT_LOCATOR" → display string
declare -a ARRAY_HANDLES=()   # unique array handles in document order; index = phys_device
declare -a DIMM_ORDER=()      # slot locators in dmidecode document order
declare -A DIMM_SIZE_GB=()    # slot locator → size in GB (0 = not installed)
declare -A DIMM_NODE=()       # slot locator → NUMA node ID (populated later)
DMIDECODE_OK=0

if [ "$NO_DIMM" = "0" ] && command -v dmidecode &>/dev/null; then
    _dmi_raw=$(dmidecode -t memory 2>/dev/null) && DMIDECODE_OK=1 || true

    if [ "$DMIDECODE_OK" = "1" ] && [ -n "$_dmi_raw" ]; then
        declare -A _seen_handles=()

        # Pass 1: collect unique Array Handles in document order → index = phys_device
        while IFS= read -r _line; do
            if [[ "$_line" =~ Array\ Handle:\ (0x[0-9A-Fa-f]+) ]]; then
                _h="${BASH_REMATCH[1]}"
                if [ -z "${_seen_handles[$_h]+x}" ]; then
                    ARRAY_HANDLES+=("$_h")
                    _seen_handles["$_h"]=1
                fi
            fi
        done <<< "$_dmi_raw"

        # Pass 2: parse each Memory Device stanza
        _cur_handle="" _cur_locator="" _cur_size="" _cur_type=""
        _cur_speed="" _cur_mfr="" _cur_part="" _in_device=0

        _store_dimm() {
            [ -z "$_cur_handle" ] || [ -z "$_cur_locator" ] && return
            local _idx=0 _h
            for _h in "${ARRAY_HANDLES[@]}"; do
                [ "$_h" = "$_cur_handle" ] && break
                _idx=$(( _idx + 1 ))
            done
            local _detail="${_cur_size} ${_cur_type} ${_cur_speed}"
            _detail="${_detail%"${_detail##*[! ]}"}"  # trim trailing whitespace
            if [ -n "$_cur_mfr" ] && [ "$_cur_mfr" != "Unknown" ] &&
               [ "$_cur_mfr" != "Not Specified" ] &&
               [ -n "$_cur_part" ] && [ "$_cur_part" != "Unknown" ] &&
               [ "$_cur_part" != "Not Specified" ]; then
                _detail+=" (${_cur_mfr} ${_cur_part})"
            fi
            DIMM_DATA["${_idx}:${_cur_locator}"]="$_detail"
            DIMM_ORDER+=("$_cur_locator")
            # Parse size in GB (e.g. "128 GB" → 128; "No Module Installed" → 0)
            local _gb=0
            if [[ "$_cur_size" =~ ^([0-9]+)[[:space:]]*GB ]]; then
                _gb="${BASH_REMATCH[1]}"
            elif [[ "$_cur_size" =~ ^([0-9]+)[[:space:]]*MB ]]; then
                _gb=$(( BASH_REMATCH[1] / 1024 ))
            fi
            DIMM_SIZE_GB["$_cur_locator"]="$_gb"
        }

        while IFS= read -r _line; do
            if [[ "$_line" == "Memory Device" ]]; then
                _store_dimm
                _cur_handle="" _cur_locator="" _cur_size="" _cur_type=""
                _cur_speed="" _cur_mfr="" _cur_part=""
                _in_device=1
                continue
            fi
            [ "$_in_device" = "0" ] && continue
            # Strip leading whitespace (dmidecode indents fields with a tab)
            _line="${_line#"${_line%%[! $'\t']*}"}"
            case "$_line" in
                "Array Handle: "*)   _cur_handle="${_line#Array Handle: }" ;;
                "Locator: "*)        _cur_locator="${_line#Locator: }" ;;
                "Size: "*)           _cur_size="${_line#Size: }" ;;
                "Type: "*)           _cur_type="${_line#Type: }" ;;
                "Speed: "*)          _cur_speed="${_line#Speed: }" ;;
                "Manufacturer: "*)   _cur_mfr="${_line#Manufacturer: }" ;;
                "Part Number: "*)    _cur_part="${_line#Part Number: }" ;;
            esac
        done <<< "$_dmi_raw"
        _store_dimm  # flush last stanza

        unset _dmi_raw _seen_handles _cur_handle _cur_locator _cur_size
        unset _cur_type _cur_speed _cur_mfr _cur_part _in_device _h _idx
    fi
fi

# ── Helpers ────────────────────────────────────────────────────────────────────

device_color() {
    local class_hex="$1"
    local class_int
    class_int=$(printf '%d' "$class_hex" 2>/dev/null) || { echo "$RESET"; return; }
    local top=$(( class_int >> 16 ))
    case "$top" in
        1)  echo "${BLUE}"            ;;  # Storage
        2)  echo "${MAGENTA}"         ;;  # Network
        3)  echo "${GREEN}"           ;;  # Display/GPU
        18) echo "${BOLD}${YELLOW}"   ;;  # Processing accelerator (0x12)
        4)  echo "${YELLOW}"          ;;  # Multimedia
        12) echo "${CYAN}"            ;;  # Serial bus (USB etc.)
        *)  echo "${WHITE}"           ;;
    esac
}

short_name() {
    local bdf="$1"
    if command -v lspci &>/dev/null; then
        lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //' | cut -c1-70
    else
        local v d
        v=$(cat "/sys/bus/pci/devices/$bdf/vendor" 2>/dev/null || echo "?")
        d=$(cat "/sys/bus/pci/devices/$bdf/device" 2>/dev/null || echo "?")
        echo "${v}:${d}"
    fi
}

get_driver() {
    local dev_path="$1"
    if [ -L "${dev_path}driver" ]; then
        basename "$(readlink "${dev_path}driver")"
    else
        echo "none"
    fi
}
get_subsystem() {
    local bdf="$1"
    if command -v lspci &>/dev/null; then
        lspci -v -s "$bdf" 2>/dev/null | awk '/Subsystem:/ {sub(/^[[:space:]]*Subsystem:[[:space:]]*/,""); print; exit}'
    fi
}

# Convert GT/s speed to PCIe generation label
speed_to_gen() {
    case "$1" in
        "2.5 GT/s PCIe"|"2.5GT/s") echo "Gen1" ;;
        "5.0 GT/s PCIe"|"5.0GT/s") echo "Gen2" ;;
        "8.0 GT/s PCIe"|"8.0GT/s") echo "Gen3" ;;
        "16.0 GT/s PCIe"|"16.0GT/s") echo "Gen4" ;;
        "32.0 GT/s PCIe"|"32.0GT/s") echo "Gen5" ;;
        "64.0 GT/s PCIe"|"64.0GT/s") echo "Gen6" ;;
        *) echo "$1" ;;
    esac
}

get_link_info() {
    local dev_path="$1"
    local cur_speed cur_width max_speed max_width
    cur_speed=$(cat "${dev_path}current_link_speed" 2>/dev/null || echo "")
    cur_width=$(cat "${dev_path}current_link_width" 2>/dev/null || echo "")
    max_speed=$(cat "${dev_path}max_link_speed" 2>/dev/null || echo "")
    max_width=$(cat "${dev_path}max_link_width" 2>/dev/null || echo "")

    [ -z "$cur_speed" ] && return
    # Suppress for on-die devices with no real PCIe link (width=0)
    [ "${cur_width:-0}" = "0" ] && return

    local cur_gen max_gen
    cur_gen=$(speed_to_gen "$cur_speed")
    max_gen=$(speed_to_gen "$max_speed")

    if [ "$cur_gen" = "$max_gen" ] && [ "$cur_width" = "$max_width" ]; then
        echo "${cur_gen} x${cur_width}"
    else
        echo "${cur_gen} x${cur_width} (max: ${max_gen} x${max_width})"
    fi
}


is_bridge() {
    # class 0x0604xx = PCI-PCI bridge / root port
    local class_hex
    class_hex=$(cat "$1/class" 2>/dev/null || echo "0")
    local class_int
    class_int=$(printf '%d' "$class_hex" 2>/dev/null) || return 1
    local sub=$(( (class_int >> 8) & 0xFFFF ))
    [ "$sub" -eq 1540 ] && return 0  # 0x0604
    return 1
}

is_endpoint() {
    local class_hex
    class_hex=$(cat "$1/class" 2>/dev/null || echo "0")
    local class_int
    class_int=$(printf '%d' "$class_hex" 2>/dev/null) || return 1
    local top=$(( class_int >> 16 ))
    # Skip unclassified (0) and bridge (6)
    [ "$top" -eq 0 ] && return 1
    [ "$top" -eq 6 ] && return 1
    return 0
}

has_link() {
    # Returns 0 (true) if device has an active PCIe link.
    # Primary check: current_link_width > 0 from sysfs.
    # Fallback: device is under a PCIe bridge (not directly on root bus),
    # which means it IS a PCIe device even if sysfs link width reads 0
    # (common for some NICs/controllers on certain server firmware versions).
    local width
    width=$(cat "$1/current_link_width" 2>/dev/null || echo "0")
    if [ "${width:-0}" -gt 0 ]; then
        return 0
    fi
    # Fallback: check if the raw symlink path has a bridge parent (not pci* root)
    local raw_link parent_name
    raw_link=$(readlink "$1" 2>/dev/null || readlink "${1%/}" 2>/dev/null || true)
    if [ -n "$raw_link" ]; then
        parent_name=$(basename "$(dirname "$raw_link")" 2>/dev/null || true)
        # If parent is a BDF (not pciXXXX:XX root domain), device is behind a bridge
        if [ -n "$parent_name" ] && [[ "$parent_name" != pci* ]]; then
            return 0
        fi
    fi
    return 1
}

# ── Build PCIe tree from sysfs paths ──────────────────────────────────────────
# sysfs path encodes hierarchy:
#   /sys/devices/pci0000:00/0000:00:06.0/0000:04:00.0
# means: root bus 0000:00 → bridge 0000:00:06.0 → endpoint 0000:04:00.0

declare -A DEV_PARENT   # BDF → parent BDF (or "root:DOMAIN" for root bus)
declare -A DEV_CHILDREN # BDF → space-separated child BDFs
declare -A DEV_NUMA     # BDF → numa_node
declare -A DEV_CLASS    # BDF → class hex
declare -A DEV_DOMAIN   # root domain → space-separated root-level BDFs
declare -A no_numa_roots=()  # root-bus-child BDFs whose subtree has numa_node=-1 devices

for dev_path in /sys/bus/pci/devices/*/; do
    bdf=$(basename "$dev_path")

    # Extract parent from the raw symlink — more reliable than readlink -f
    # The symlink value encodes the full PCI hierarchy, e.g.:
    #   ../../../devices/pci0000:00/0000:00:1c.4/0000:01:00.0
    # so dirname gives the parent directory, and basename of that is the parent BDF.
    raw_link=$(readlink "$dev_path" 2>/dev/null || true)
    if [ -z "$raw_link" ]; then
        # Fallback: try readlink -f and strip /sys/devices prefix
        raw_link=$(readlink -f "$dev_path" 2>/dev/null | sed 's|/sys/devices/|../../../devices/|' || true)
    fi

    parent_path=$(dirname "$raw_link" 2>/dev/null || true)
    parent_part=$(basename "$parent_path" 2>/dev/null || true)

    if [ -z "$parent_part" ] || [ "$parent_part" = "." ]; then
        # Could not determine parent — skip tree placement but still track NUMA
        parent_part=""
    fi

    if [ -n "$parent_part" ]; then
        if [[ "$parent_part" == pci* ]]; then
            # Direct child of root bus
            domain="${parent_part#pci}"
            DEV_PARENT["$bdf"]="root:${domain}"
            DEV_DOMAIN["$domain"]+=" $bdf"
        else
            # Child of a bridge
            DEV_PARENT["$bdf"]="$parent_part"
            DEV_CHILDREN["$parent_part"]+=" $bdf"
        fi
    fi

    numa_node=$(cat "${dev_path}numa_node" 2>/dev/null | tr -d '[:space:]' || echo "-1")
    numa_node="${numa_node:-"-1"}"
    DEV_NUMA["$bdf"]="$numa_node"
    DEV_CLASS["$bdf"]=$(cat "${dev_path}class" 2>/dev/null || echo "0x000000")
done

# ── PCIe switch detection ────────────────────────────────────────────────────
# Detect PCIe switch ports from lspci device names (single call).
# An upstream port is a switch port whose parent is NOT another switch port.
# Propagate the upstream BDF to all descendants so endpoints know their switch.

declare -A IS_SWITCH=()          # BDF → 1 if bridge is a switch port
declare -A DEV_SWITCH=()         # BDF → upstream switch BDF (for any device behind a switch)

if command -v lspci &>/dev/null; then
    while IFS= read -r _line; do
        [[ "$_line" =~ ^([0-9a-f:.]+)[[:space:]] ]] || continue
        _bdf="${BASH_REMATCH[1]}"
        # Normalize to domain:bus:dev.fn
        [[ "$_bdf" == *:*:* ]] || _bdf="0000:${_bdf}"
        if [[ "${_line,,}" == *switch* ]] && [[ "$_line" == *"PCI bridge"* ]]; then
            IS_SWITCH["$_bdf"]=1
        fi
    done < <(lspci 2>/dev/null)
fi

# Walk the tree to propagate switch ancestry
_propagate_switch() {
    local bdf="$1" up_bdf="$2"
    DEV_SWITCH["$bdf"]="$up_bdf"
    local children="${DEV_CHILDREN[$bdf]:-}"
    local child
    for child in $children; do
        _propagate_switch "$child" "$up_bdf"
    done
}

for _sbdf in "${!IS_SWITCH[@]}"; do
    local_par="${DEV_PARENT[$_sbdf]:-}"
    if [[ "$local_par" == root:* ]] || [ -z "${IS_SWITCH[$local_par]+x}" ]; then
        # This is an upstream port — propagate to all descendants
        _propagate_switch "$_sbdf" "$_sbdf"
    fi
done
unset _sbdf local_par

# Find the root port for a given BDF (the bridge whose parent is root:*)
get_root_port() {
    local cur="$1" prev=""
    while true; do
        local par="${DEV_PARENT[$cur]:-}"
        [ -z "$par" ] && break
        if [[ "$par" == root:* ]]; then
            echo "$cur"
            return
        fi
        cur="$par"
    done
}

# ── Print tree for a given node ───────────────────────────────────────────────

print_device() {
    local bdf="$1"
    local prefix="$2"       # tree drawing prefix so far
    local is_last="$3"      # 1 if last sibling
    local dev_path="/sys/bus/pci/devices/${bdf}/"

    local class="${DEV_CLASS[$bdf]:-0x000000}"
    local color
    color=$(device_color "$class")
    local name
    name=$(short_name "$bdf")
    local driver
    driver=$(get_driver "$dev_path")

    # Tree connector
    local connector branch_prefix
    if [ "$is_last" = "1" ]; then
        connector="└──"
        branch_prefix="${prefix}    "
    else
        connector="├──"
        branch_prefix="${prefix}│   "
    fi

    # Extra annotations
    local extras=""
    if [ -f "${dev_path}sriov_numvfs" ]; then
        local numvfs totalvfs
        numvfs=$(cat "${dev_path}sriov_numvfs" 2>/dev/null || echo 0)
        totalvfs=$(cat "${dev_path}sriov_totalvfs" 2>/dev/null || echo 0)
        extras=" ${DIM}[SR-IOV ${numvfs}/${totalvfs} VFs]${RESET}"
    fi
    if [ -L "${dev_path}iommu_group" ]; then
        local grp
        grp=$(basename "$(readlink "${dev_path}iommu_group")")
        extras+=" ${DIM}[IOMMU grp ${grp}]${RESET}"
    fi

    if is_bridge "$dev_path"; then
        # Bridge/root port: suppress if no visible descendants
        # (respects both --pcie and class filter flags)
        if [ "$PCIE_ONLY" = "1" ] || [ "$FILTER_ACTIVE" = "1" ]; then
            local has_visible=0
            _check_visible_children() {
                local check_bdf="$1"
                local kids="${DEV_CHILDREN[$check_bdf]:-}"
                [ -z "$kids" ] && return 1
                local k
                for k in $kids; do
                    local kpath="/sys/bus/pci/devices/${k}/"
                    if is_bridge "$kpath"; then
                        _check_visible_children "$k" && return 0
                    else
                        # Check PCIe link filter
                        if [ "$PCIE_ONLY" = "1" ] && ! has_link "$kpath"; then
                            continue
                        fi
                        # Check class filter
                        local kclass="${DEV_CLASS[$k]:-0x000000}"
                        if class_matches_filter "$kclass"; then
                            return 0
                        fi
                    fi
                done
                return 1
            }
            _check_visible_children "$bdf" && has_visible=1
            if [ "$has_visible" = "0" ]; then
                return
            fi
        fi
        if [ -n "${IS_SWITCH[$bdf]+x}" ]; then
            # Check if this is an upstream port (parent is not a switch port)
            local _par="${DEV_PARENT[$bdf]:-}"
            if [[ "$_par" == root:* ]] || [ -z "${IS_SWITCH[$_par]+x}" ]; then
                # Upstream port — highlight as switch entry point
                echo -e "${prefix}${connector} ${YELLOW}${bdf}${RESET}  ${YELLOW}${name}${RESET}  ${DIM}[upstream]${RESET}"
            else
                echo -e "${prefix}${DIM}${connector} ${bdf}${RESET}  ${DIM}${name}${RESET}  ${DIM}[downstream]${RESET}"
            fi
        else
            echo -e "${prefix}${DIM}${connector} ${bdf}${RESET}  ${DIM}${name}${RESET}"
        fi
    else
        # Skip on-die devices when --pcie flag is set
        if [ "$PCIE_ONLY" = "1" ] && ! has_link "$dev_path"; then
            return
        fi

        # Skip devices that don't match class filter
        if ! class_matches_filter "$class"; then
            return
        fi

        # Endpoint — colored, show name + annotations
        echo -e "${prefix}${connector} ${color}${BOLD}${bdf}${RESET}  ${color}${name}${RESET}${extras}"

        # Subsystem (board/card name — often more descriptive than chip name)
        local subsystem link_info detail_line
        subsystem=$(get_subsystem "$bdf")
        link_info=$(get_link_info "$dev_path")

        # Build detail line: driver | link speed | subsystem
        detail_line="${DIM}driver: ${BOLD}${driver}${RESET}"
        if [ -n "$link_info" ]; then
            detail_line+="${DIM}  |  link: ${BOLD}${link_info}${RESET}"
        fi
        echo -e "${branch_prefix}${detail_line}"

        if [ -n "$subsystem" ] && [ "$subsystem" != "$name" ]; then
            echo -e "${branch_prefix}${DIM}subsystem: ${subsystem}${RESET}"
        fi
    fi

    # Print children
    local children="${DEV_CHILDREN[$bdf]:-}"
    if [ -n "$children" ]; then
        # Sort children
        local child_list
        read -ra child_list <<< "${children# }"
        local total=${#child_list[@]}
        local idx=0
        for child in "${child_list[@]}"; do
            idx=$(( idx + 1 ))
            local child_is_last=0
            if [ "$idx" -eq "$total" ]; then child_is_last=1; fi
            print_device "$child" "$branch_prefix" "$child_is_last"
        done
    fi
}

print_numa_tree() {
    local node_id="$1"

    # Collect root buses whose devices belong to this NUMA node
    # A root bus "belongs" to a node if any of its descendant endpoints are on that node
    # We find root-level BDFs (direct children of root bus) that have descendants on this node

    # Gather all endpoints on this node (respecting class filter)
    local node_endpoints=()
    for bdf in "${!DEV_NUMA[@]}"; do
        [ "${DEV_NUMA[$bdf]}" = "$node_id" ] || continue
        local dev_path="/sys/bus/pci/devices/${bdf}/"
        is_endpoint "$dev_path" || continue
        local ep_class="${DEV_CLASS[$bdf]:-0x000000}"
        class_matches_filter "$ep_class" || continue
        node_endpoints+=("$bdf")
    done

    if [ ${#node_endpoints[@]} -eq 0 ]; then
        echo -e "  ${DIM}(no PCIe devices on this NUMA node)${RESET}"
        return
    fi

    # Find the root-level BDFs (direct children of root buses) that are
    # ancestors of the node's endpoints
    declare -A roots_to_show

    for ep in "${node_endpoints[@]}"; do
        # Walk up to find the root-bus child
        local cur="$ep"
        while true; do
            local par="${DEV_PARENT[$cur]:-}"
            [ -z "$par" ] && break
            if [[ "$par" == root:* ]]; then
                roots_to_show["$cur"]=1
                break
            fi
            cur="$par"
        done
    done

    # Print each root subtree that contains devices on this node
    local root_list=("${!roots_to_show[@]}")
    # Sort
    IFS=$'\n' root_list=($(printf '%s\n' "${root_list[@]}" | sort))
    IFS=' 	
'
    local total=${#root_list[@]}
    local idx=0

    echo -e "  ${DIM}PCIe topology:${RESET}"
    echo ""

    for root_bdf in "${root_list[@]}"; do
        idx=$(( idx + 1 ))
        local is_last=0
        [ "$idx" -eq "$total" ] && is_last=1
        print_device "$root_bdf" "  " "$is_last"
    done
}

# ── Flat device list for a given node ─────────────────────────────────────────

print_numa_flat() {
    local node_id="$1"
    local endpoints=()

    for bdf in "${!DEV_NUMA[@]}"; do
        [ "${DEV_NUMA[$bdf]}" = "$node_id" ] || continue
        local dev_path="/sys/bus/pci/devices/${bdf}/"
        is_endpoint "$dev_path" || continue
        if [ "$PCIE_ONLY" = "1" ] && ! has_link "$dev_path"; then continue; fi
        local bdf_class="${DEV_CLASS[$bdf]:-0x000000}"
        class_matches_filter "$bdf_class" || continue
        endpoints+=("$bdf")
    done

    if [ ${#endpoints[@]} -eq 0 ]; then
        echo -e "  ${DIM}(no PCIe devices on this NUMA node)${RESET}"
        return
    fi

    IFS=$'\n' endpoints=($(printf '%s\n' "${endpoints[@]}" | sort))
    IFS=$' \t\n'

    echo -e "  ${DIM}PCIe devices:${RESET}"
    echo ""

    for bdf in "${endpoints[@]}"; do
        local dev_path="/sys/bus/pci/devices/${bdf}/"
        local class="${DEV_CLASS[$bdf]:-0x000000}"
        local color; color=$(device_color "$class")
        local name; name=$(short_name "$bdf")
        local driver; driver=$(get_driver "$dev_path")
        local link_info; link_info=$(get_link_info "$dev_path")

        local extras=""
        if [ -f "${dev_path}sriov_numvfs" ]; then
            local numvfs totalvfs
            numvfs=$(cat "${dev_path}sriov_numvfs" 2>/dev/null || echo 0)
            totalvfs=$(cat "${dev_path}sriov_totalvfs" 2>/dev/null || echo 0)
            extras=" ${DIM}[SR-IOV ${numvfs}/${totalvfs} VFs]${RESET}"
        fi
        if [ -L "${dev_path}iommu_group" ]; then
            local grp; grp=$(basename "$(readlink "${dev_path}iommu_group")")
            extras+=" ${DIM}[IOMMU grp ${grp}]${RESET}"
        fi

        echo -e "  ${color}${BOLD}${bdf}${RESET}  ${color}${name}${RESET}${extras}"

        local detail_line="${DIM}driver: ${BOLD}${driver}${RESET}"
        [ -n "$link_info" ] && detail_line+="${DIM}  |  link: ${BOLD}${link_info}${RESET}"
        local sw_bdf="${DEV_SWITCH[$bdf]:-}"
        if [ -n "$sw_bdf" ]; then
            local sw_name; sw_name=$(short_name "$sw_bdf")
            detail_line+="${DIM}  |  switch: ${BOLD}${sw_bdf}${RESET}${DIM} (${sw_name})${RESET}"
        fi
        local rp_bdf; rp_bdf=$(get_root_port "$bdf")
        if [ -n "$rp_bdf" ]; then
            detail_line+="${DIM}  |  root port: ${BOLD}${rp_bdf}${RESET}"
        fi
        echo -e "  ${detail_line}"

        local subsystem; subsystem=$(get_subsystem "$bdf")
        if [ -n "$subsystem" ] && [ "$subsystem" != "$name" ]; then
            echo -e "  ${DIM}subsystem: ${subsystem}${RESET}"
        fi
        echo ""
    done
}

# ── Hugepages per NUMA node ───────────────────────────────────────────────────

print_hugepages() {
    local node_id="$1"
    local hp_base="/sys/devices/system/node/node${node_id}/hugepages"
    local output=""

    for size_label in 2048kB 1048576kB; do
        local size_dir="${hp_base}/hugepages-${size_label}"
        [ -d "$size_dir" ] || continue

        local nr free
        nr=$(cat "${size_dir}/nr_hugepages"    2>/dev/null || echo 0)
        free=$(cat "${size_dir}/free_hugepages" 2>/dev/null || echo 0)
        [ "${nr:-0}" -eq 0 ] && continue

        local human_label
        case "$size_label" in
            2048kB)    human_label="2M" ;;
            1048576kB) human_label="1G" ;;
            *)         human_label="$size_label" ;;
        esac

        if [ -n "$output" ]; then
            output+="  ${DIM}|${RESET}  "
        fi
        output+="${human_label}: ${nr} total, ${free} free"
    done

    if [ -z "$output" ]; then
        echo -e "  ${BOLD}${GREEN}Hugepages:${RESET}  ${DIM}(none allocated)${RESET}"
    else
        echo -e "  ${BOLD}${GREEN}Hugepages:${RESET}  ${output}"
    fi
}

# ── DIMM info per NUMA node ───────────────────────────────────────────────────

print_dimm_info() {
    local node_id="$1"
    local _dimm_lines=()

    if [ "${#DIMM_NODE[@]}" -gt 0 ]; then
        # Cumulative-size heuristic: use DIMM_NODE mapping
        for _slot in "${DIMM_ORDER[@]}"; do
            [ "${DIMM_NODE[$_slot]:-}" = "$node_id" ] || continue
            local _key
            for _key in "${!DIMM_DATA[@]}"; do
                [ "${_key#*:}" = "$_slot" ] || continue
                local _detail="${DIMM_DATA[$_key]}"
                [[ "$_detail" == *"No Module Installed"* ]] && continue
                [[ "$_detail" =~ ^[[:space:]]*$ ]] && continue
                _dimm_lines+=("${_slot}: ${_detail}")
                break
            done
        done
    else
        # phys_device correlation
        local node_path="/sys/devices/system/node/node${node_id}"
        declare -A _node_phys=()
        local _mb _pd
        for _mb in "${node_path}"/memory*/; do
            [ -d "$_mb" ] || continue
            _pd=$(cat "${_mb}phys_device" 2>/dev/null | tr -d '[:space:]') || continue
            [ -n "$_pd" ] && _node_phys["$_pd"]=1
        done
        [ ${#_node_phys[@]} -eq 0 ] && return
        local _key
        for _key in "${!DIMM_DATA[@]}"; do
            local _aidx="${_key%%:*}"
            local _slot="${_key#*:}"
            [ -n "${_node_phys[$_aidx]+x}" ] || continue
            local _detail="${DIMM_DATA[$_key]}"
            [[ "$_detail" == *"No Module Installed"* ]] && continue
            [[ "$_detail" =~ ^[[:space:]]*$ ]] && continue
            _dimm_lines+=("${_slot}: ${_detail}")
        done
        IFS=$'\n' _dimm_lines=($(printf '%s\n' "${_dimm_lines[@]}" | sort))
        IFS=$' \t\n'
    fi

    local _first=1 _dl
    for _dl in "${_dimm_lines[@]}"; do
        if [ "$_first" = "1" ]; then
            echo -e "  ${BOLD}${GREEN}DIMMs:${RESET}     ${_dl}"
            _first=0
        else
            echo -e "             ${_dl}"
        fi
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

NUMA_NODES=$(ls /sys/devices/system/node/ | grep -cE '^node[0-9]+$' || true)

if [ "$NUMA_NODES" -eq 0 ]; then
    echo "No NUMA nodes found."
    exit 1
fi

# ── CPU model and socket detection ───────────────────────────────────────────
# Build per-socket CPU model name from /proc/cpuinfo
declare -A SOCKET_MODEL=()
declare -A SOCKET_SET=()

while IFS= read -r _line; do
    case "$_line" in
        "physical id"*)  _phys_id="${_line#*: }" ;;
        "model name"*)
            _model="${_line#*: }"
            if [ -n "${_phys_id:-}" ] && [ -z "${SOCKET_MODEL[$_phys_id]+x}" ]; then
                SOCKET_MODEL["$_phys_id"]="$_model"
                SOCKET_SET["$_phys_id"]=1
            fi
            ;;
    esac
done < /proc/cpuinfo
unset _line _phys_id _model

NUM_SOCKETS=${#SOCKET_SET[@]}

# ── DIMM-to-NUMA correlation ──────────────────────────────────────────────────
# Try phys_device first. If all blocks share one phys_device (single-array
# firmware), fall back to cumulative-size heuristic: walk DIMMs in dmidecode
# document order (= memory controller order = physical address order), accumulate
# sizes, and assign each DIMM to the NUMA node whose MemTotal it fills next.
# Nodes are processed in physical address order (lowest memory block first).


if [ "$DMIDECODE_OK" = "1" ]; then
    # Check whether phys_device gives useful per-node discrimination
    declare -A _all_phys=()
    for _mb in /sys/devices/system/memory/memory*/; do
        _pd=$(cat "${_mb}phys_device" 2>/dev/null | tr -d '[:space:]') || continue
        [ -n "$_pd" ] && _all_phys["$_pd"]=1
    done
    _single_array=0
    [ "${#_all_phys[@]}" -le 1 ] && [ "$NUMA_NODES" -gt 1 ] && _single_array=1
    unset _all_phys _mb _pd

    if [ "$_single_array" = "1" ]; then
        # Cumulative-size heuristic
        # 1. Sort nodes by their lowest memory block number (= physical address order)
        declare -a _node_order=()
        declare -A _node_min_block=()
        for _np in /sys/devices/system/node/node*/; do
            _nid="${_np%/}"; _nid="${_nid##*/node}"
            _min=9999999999
            for _mb in "${_np}"memory*/; do
                _bn="${_mb%/}"; _bn="${_bn##*/memory}"
                [[ "$_bn" =~ ^[0-9]+$ ]] || continue
                [ "$_bn" -lt "$_min" ] && _min=$_bn
            done
            _node_min_block["$_nid"]=$_min
            _node_order+=("$_nid")
        done
        IFS=$'\n' _node_order=($(for _n in "${_node_order[@]}"; do
            echo "${_node_min_block[$_n]} $_n"
        done | sort -n | awk '{print $2}'))
        IFS=$' \t\n'

        # 2. Get each node's MemTotal in GB
        declare -A _node_mem_gb=()
        for _n in "${_node_order[@]}"; do
            _kb=$(awk '/MemTotal/ {print $4}' \
                "/sys/devices/system/node/node${_n}/meminfo" 2>/dev/null || echo 0)
            _node_mem_gb["$_n"]=$(( _kb / 1024 / 1024 ))
        done

        # 3. Walk DIMMs in document order, assign to nodes
        _nidx=0
        _cumulative_gb=0
        _cur_node="${_node_order[$_nidx]:-}"
        for _slot in "${DIMM_ORDER[@]}"; do
            _sz="${DIMM_SIZE_GB[$_slot]:-0}"
            [ "$_sz" -eq 0 ] && continue   # skip empty slots
            DIMM_NODE["$_slot"]="${_cur_node}"
            _cumulative_gb=$(( _cumulative_gb + _sz ))
            # Advance to next node when we've filled 90% of current node's memory
            _threshold=$(( _node_mem_gb["${_cur_node}"] * 90 / 100 ))
            _next_nidx=$(( _nidx + 1 ))
            if [ "$_cumulative_gb" -ge "$_threshold" ] \
               && [ "$_next_nidx" -lt "${#_node_order[@]}" ]; then
                _nidx=$_next_nidx
                _cur_node="${_node_order[$_nidx]}"
                _cumulative_gb=0
            fi
        done
        unset _node_order _node_min_block _node_mem_gb _np _nid _min _mb _bn
        unset _n _kb _nidx _cumulative_gb _cur_node _threshold _slot _sz _next_nidx
    fi
    unset _single_array
fi

if [ "$NUM_SOCKETS" -gt 0 ]; then
    echo -e "${BOLD}NUMA Topology${RESET}  (${NUM_SOCKETS} socket(s), ${NUMA_NODES} node(s))"
else
    echo -e "${BOLD}NUMA Topology${RESET}  (${NUMA_NODES} node(s))"
fi
echo ""

for node_path in /sys/devices/system/node/node*/; do
    node=$(basename "$node_path")
    node_id="${node#node}"

    # Determine socket for this NUMA node from the first CPU's physical_package_id
    node_socket=""
    if [ -f "${node_path}cpulist" ]; then
        cpulist=$(cat "${node_path}cpulist")
        first_cpu=$(echo "$cpulist" | tr ',' '\n' | head -1 | tr '-' '\n' | head -1)
        node_socket=$(cat "/sys/devices/system/cpu/cpu${first_cpu}/topology/physical_package_id" 2>/dev/null || true)
    fi

    if [ -n "$node_socket" ]; then
        echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}${CYAN}║  NUMA Node ${node_id}  ·  Socket ${node_socket}${RESET}"
        echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    else
        echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}${CYAN}║  NUMA Node ${node_id}${RESET}"
        echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    fi

    # CPUs
    if [ -f "${node_path}cpulist" ]; then
        cpu_model="${SOCKET_MODEL[${node_socket:-}]:-}"
        if [ -n "$cpu_model" ]; then
            echo -e "  ${BOLD}${GREEN}CPUs:${RESET}   ${cpulist}  ${DIM}(${cpu_model})${RESET}"
        else
            echo -e "  ${BOLD}${GREEN}CPUs:${RESET}   ${cpulist}"
        fi
    fi

    # Memory
    if [ -f "${node_path}meminfo" ]; then
        total=$(awk '/MemTotal/ {printf "%.1f GB", $4/1024/1024}' "${node_path}meminfo")
        free=$(awk '/MemFree/ {printf "%.1f GB", $4/1024/1024}' "${node_path}meminfo")
        echo -e "  ${BOLD}${GREEN}Memory:${RESET} ${total} total, ${free} free"
    fi

    # Hugepages (always shown)
    print_hugepages "$node_id"

    # DIMMs per node (only if dmidecode succeeded)
    if [ "$DMIDECODE_OK" = "1" ]; then
        print_dimm_info "$node_id"
    fi

    echo ""
    if [ "$FLAT" = "1" ]; then
        print_numa_flat "$node_id"
    else
        print_numa_tree "$node_id"
        echo ""
    fi
done

# Devices with no NUMA affinity
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║  No NUMA Affinity  (numa_node = -1)${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"

for bdf in "${!DEV_NUMA[@]}"; do
    [ "${DEV_NUMA[$bdf]}" = "-1" ] || continue
    local_dev_path="/sys/bus/pci/devices/${bdf}/"
    is_endpoint "$local_dev_path" || continue
    local_class="${DEV_CLASS[$bdf]:-0x000000}"
    class_matches_filter "$local_class" || continue

    # Walk up to root-bus child
    cur="$bdf"
    while true; do
        par="${DEV_PARENT[$cur]:-}"
        [ -z "$par" ] && break
        if [[ "$par" == root:* ]]; then
            no_numa_roots["$cur"]=1
            break
        fi
        cur="$par"
    done
done

if [ ${#no_numa_roots[@]} -eq 0 ] && [ "$FLAT" = "0" ]; then
    echo -e "  ${DIM}(none)${RESET}"
elif [ "$FLAT" = "1" ]; then
    print_numa_flat "-1"
else
    echo ""
    IFS=$'\n' no_numa_list=($(printf '%s\n' "${!no_numa_roots[@]}" | sort))
    IFS='
'
    total=${#no_numa_list[@]}
    idx=0
    for root_bdf in "${no_numa_list[@]}"; do
        idx=$(( idx + 1 ))
        is_last=0
        [ "$idx" -eq "$total" ] && is_last=1
        print_device "$root_bdf" "  " "$is_last"
    done
fi

echo ""


# Legend
echo -e "${DIM}Legend:${RESET}"
echo -e "  ${BOLD}${YELLOW}■${RESET} Processing Accelerator (GPU/NPU)   ${BOLD}${MAGENTA}■${RESET} Network"
echo -e "  ${BOLD}${BLUE}■${RESET} Storage                             ${BOLD}${GREEN}■${RESET} Display"
echo -e "  ${BOLD}${CYAN}■${RESET} Serial Bus (USB/TB)                 ${DIM}dim = bridge/root port${RESET}"

#!/bin/bash
# hw-topology.sh — Display NUMA nodes with CPUs and PCIe device topology tree

set -uo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────
PCIE_ONLY=0
NO_DIMM=0
FLAT=0
SIMPLE=0

# Device class filters (additive — if none set, show all)
declare -A CLASS_FILTER=()

for arg in "$@"; do
    case "$arg" in
        -p|--pcie)          PCIE_ONLY=1 ;;
        -f|--flat)          FLAT=1 ;;
        -t|--simple)        SIMPLE=1 ;;
        --no-dimm)          NO_DIMM=1 ;;
        -a|--accelerators)  CLASS_FILTER[18]=1; CLASS_FILTER[3]=1 ;;   # 0x12 = Processing accelerator + 0x03 = 3D/Display (GPUs)
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
            echo "  -t, --simple        Compact view: Socket → NUMA → pcieRoot → devices by type"
            echo "  --no-dimm           Skip DIMM info (no dmidecode; faster for non-root users)"
            echo ""
            echo "Device class filters (additive — combine to show multiple categories):"
            echo "  -a, --accelerators  GPUs and processing accelerators (class 0x03 + 0x12)"
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

# ── Per-device pcieRoot lookup ───────────────────────────────────────────────
# Walk DEV_PARENT to find the root bus for every device (e.g. "00", "d0").

declare -A DEV_PCIE_ROOT=()
declare -A DEV_PCIE_ROOT_DOMAIN=()   # BDF → full domain:bus (e.g. "0000:d0")
for _bdf in "${!DEV_PARENT[@]}"; do
    _cur="$_bdf"
    while true; do
        _par="${DEV_PARENT[$_cur]:-}"
        [ -z "$_par" ] && break
        if [[ "$_par" == root:* ]]; then
            _full="${_par#root:}"        # e.g. "0000:d0"
            _rb="${_full#*:}"            # e.g. "d0"
            DEV_PCIE_ROOT["$_bdf"]="$_rb"
            DEV_PCIE_ROOT_DOMAIN["$_bdf"]="$_full"
            break
        fi
        _cur="$_par"
    done
done
unset _bdf _cur _par _full _rb

# ── SLIT distance matrix ────────────────────────────────────────────────────
# Read NUMA inter-node distances from sysfs (one row per node).

declare -A SLIT_DIST=()      # "src:dst" → distance (e.g. "0:1" → 32)
SLIT_NODES=()                # sorted node IDs with distance data

for _np in /sys/devices/system/node/node*/; do
    _nid="${_np%/}"; _nid="${_nid##*/node}"
    [ -f "${_np}distance" ] || continue
    SLIT_NODES+=("$_nid")
    _col=0
    for _d in $(cat "${_np}distance"); do
        SLIT_DIST["${_nid}:${_col}"]="$_d"
        _col=$((_col + 1))
    done
done
IFS=$'\n' SLIT_NODES=($(printf '%s\n' "${SLIT_NODES[@]}" | sort -n))
IFS=$' \t\n'
unset _np _nid _col _d

# ── GPU partition mode detection ─────────────────────────────────────────────
# AMD: ROCm compute/memory partitions via /sys/class/drm/card*/device/
# NVIDIA: MIG mode via nvidia-smi (if available)
# Maps PCI BDF → current/available partition modes.

declare -A GPU_COMPUTE_PART=()     # BDF → current mode (e.g. "SPX" or "MIG enabled")
declare -A GPU_COMPUTE_AVAIL=()    # BDF → available modes (e.g. "SPX, DPX, QPX, CPX")
declare -A GPU_MEMORY_PART=()      # BDF → current mode (e.g. "NPS1")
declare -A GPU_MEMORY_AVAIL=()     # BDF → available modes (e.g. "NPS1, NPS2")

# AMD GPU partitions (amdgpu driver)
for _card in /sys/class/drm/card[0-9]*/; do
    [ -d "${_card}device" ] || continue
    _bdf=$(basename "$(readlink -f "${_card}device")" 2>/dev/null) || continue
    _cp=$(cat "${_card}device/current_compute_partition" 2>/dev/null) || true
    _ap=$(cat "${_card}device/available_compute_partition" 2>/dev/null) || true
    _cm=$(cat "${_card}device/current_memory_partition" 2>/dev/null) || true
    _am=$(cat "${_card}device/available_memory_partition" 2>/dev/null) || true
    if [ -n "$_cp" ]; then
        GPU_COMPUTE_PART["$_bdf"]="$_cp"
        GPU_COMPUTE_AVAIL["$_bdf"]="$_ap"
    fi
    if [ -n "$_cm" ]; then
        GPU_MEMORY_PART["$_bdf"]="$_cm"
        GPU_MEMORY_AVAIL["$_bdf"]="$_am"
    fi
done
unset _card _bdf _cp _ap _cm _am

# NVIDIA MIG mode (nvidia driver)
if command -v nvidia-smi &>/dev/null; then
    while IFS=', ' read -r _bdf _mig_mode _mig_avail; do
        [ -z "$_bdf" ] && continue
        [[ "$_bdf" == *"."* ]] || continue
        # nvidia-smi uses long BDF (e.g. "00000000:1B:00.0") — normalize to "0000:1b:00.0"
        _bdf=$(echo "$_bdf" | tr '[:upper:]' '[:lower:]' | sed 's/^00000000:/0000:/')
        [[ "$_bdf" == *:*:* ]] || _bdf="0000:${_bdf}"
        _mig_mode=$(echo "$_mig_mode" | tr -d '[:space:]')
        _mig_avail=$(echo "$_mig_avail" | tr -d '[:space:]')

        if [ "$_mig_mode" = "Enabled" ]; then
            GPU_COMPUTE_PART["$_bdf"]="MIG"
            # Get MIG profiles if MIG is enabled
            _profiles=$(nvidia-smi mig -lgip --id="$_bdf" 2>/dev/null | awk '/^[| ]*[0-9]/ {print $3}' | sort -u | tr '\n' ',' | sed 's/,$//')
            GPU_COMPUTE_AVAIL["$_bdf"]="${_profiles:-MIG profiles available}"
        elif [ "$_mig_avail" = "Enabled" ]; then
            # MIG supported but not currently enabled
            GPU_COMPUTE_PART["$_bdf"]="MIG off"
            GPU_COMPUTE_AVAIL["$_bdf"]="MIG supported"
        fi
    done < <(nvidia-smi --query-gpu=pci.bus_id,mig.mode.current,mig.mode.pending --format=csv,noheader 2>/dev/null || true)
    unset _bdf _mig_mode _mig_avail _profiles
fi

# ── IOMMU instance to device mapping ─────────────────────────────────────────
# AMD: /sys/class/iommu/ivhd* — each ivhd is one IOD quadrant
# Intel: /sys/class/iommu/dmar* — each dmar is one DMAR hardware unit
# Same data structures used for both; IOMMU_TYPE tracks which.

declare -A IVHD_ROOTS=()     # iommu name → space-separated root bus IDs (e.g. "00 10")
declare -A IVHD_GPUS=()      # iommu name → space-separated GPU BDFs
declare -A IVHD_NICS=()      # iommu name → space-separated NIC BDFs
declare -A IVHD_NVME=()      # iommu name → space-separated NVMe BDFs
declare -a IVHD_LIST=()      # sorted iommu names
IVHD_AVAILABLE=0
IOMMU_TYPE=""                # "ivhd" (AMD) or "dmar" (Intel)
declare -A ROOT_TO_IVHD=()  # pcieRoot "0000:d0" → iommu name "ivhd0" or "dmar0"

_iommu_glob=""
if ls /sys/class/iommu/ivhd* &>/dev/null 2>&1; then
    _iommu_glob="/sys/class/iommu/ivhd*/"
    IOMMU_TYPE="ivhd"
elif ls /sys/class/iommu/dmar* &>/dev/null 2>&1; then
    _iommu_glob="/sys/class/iommu/dmar*/"
    IOMMU_TYPE="dmar"
fi

if [ -n "$_iommu_glob" ]; then
    IVHD_AVAILABLE=1
    for _iommu_path in $_iommu_glob; do
        _ivhd=$(basename "$_iommu_path")
        IVHD_LIST+=("$_ivhd")
        [ -d "${_iommu_path}devices" ] || continue

        declare -A _seen_roots=()
        for _dev_link in "${_iommu_path}devices/"*/; do
            _dbdf=$(basename "$_dev_link")
            [ -z "$_dbdf" ] || [ "$_dbdf" = "*" ] && continue

            # Walk DEV_PARENT to find the root complex for this device
            _root_bus=""
            _cur="$_dbdf"
            while true; do
                _par="${DEV_PARENT[$_cur]:-}"
                [ -z "$_par" ] && break
                if [[ "$_par" == root:* ]]; then
                    _root_bus="${_par#root:}"
                    _root_bus="${_root_bus#*:}"  # strip domain prefix "0000:" → "00"
                    break
                fi
                _cur="$_par"
            done
            # Skip devices we can't trace to a root (e.g. IOMMU devices themselves)
            [ -z "$_root_bus" ] && continue

            if [ -z "${_seen_roots[$_root_bus]+x}" ]; then
                _seen_roots["$_root_bus"]=1
                IVHD_ROOTS["$_ivhd"]+=" $_root_bus"
            fi

            # Classify endpoint devices
            _dclass="${DEV_CLASS[$_dbdf]:-0x000000}"
            _dclass_int=$(printf '%d' "$_dclass" 2>/dev/null) || continue
            _dtop=$(( _dclass_int >> 16 ))
            _dsub=$(( (_dclass_int >> 8) & 0xFF ))

            case "$_dtop" in
                18|3)  # Processing accelerator or Display — check if it's a GPU (not DPU)
                    _dev_path="/sys/bus/pci/devices/${_dbdf}/"
                    if [ -L "${_dev_path}driver" ]; then
                        _drv=$(basename "$(readlink "${_dev_path}driver" 2>/dev/null)" 2>/dev/null)
                        case "$_drv" in
                            amdgpu|nvidia|i915|xe) IVHD_GPUS["$_ivhd"]+=" $_dbdf" ;;
                        esac
                    fi
                    ;;
                2)   # Network controller
                    IVHD_NICS["$_ivhd"]+=" $_dbdf"
                    ;;
                1)   # Storage — check subclass for NVMe (0x08)
                    if [ "$_dsub" -eq 8 ]; then
                        IVHD_NVME["$_ivhd"]+=" $_dbdf"
                    fi
                    ;;
            esac
        done
        unset _seen_roots
    done
    IFS=$'\n' IVHD_LIST=($(printf '%s\n' "${IVHD_LIST[@]}" | sort))
    IFS=$' \t\n'
    unset _iommu_path _ivhd _dev_link _dbdf _root_bus _cur _par
    unset _dclass _dclass_int _dtop _dsub _dev_path _drv

    # Build reverse lookup: pcieRoot domain:bus → iommu name
    for _iv in "${IVHD_LIST[@]}"; do
        for _g in ${IVHD_GPUS[$_iv]:-} ${IVHD_NICS[$_iv]:-} ${IVHD_NVME[$_iv]:-}; do
            _rd="${DEV_PCIE_ROOT_DOMAIN[$_g]:-}"
            if [ -n "$_rd" ] && [ -z "${ROOT_TO_IVHD[$_rd]+x}" ]; then
                ROOT_TO_IVHD["$_rd"]="$_iv"
            fi
        done
    done
    unset _iv _g _rd
fi
unset _iommu_glob

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

# ── Physical slot detection ─────────────────────────────────────────────────
# Parse Physical Slot numbers from lspci -v for PCI bridges.
# Bridges with a Physical Slot but no endpoint children are empty slots.

declare -A BRIDGE_SLOT=()        # bridge BDF → physical slot number
declare -A BRIDGE_NUMA=()        # bridge BDF → NUMA node
declare -A SLOT_BRIDGES=()       # "numa:slot" → bridge BDF (for dedup)
declare -a EMPTY_SLOTS=()        # bridge BDFs with a physical slot but no endpoints

if command -v lspci &>/dev/null; then
    _cur_bdf=""
    while IFS= read -r _line; do
        if [[ "$_line" =~ ^([0-9a-f:.]+)[[:space:]] ]]; then
            _cur_bdf="${BASH_REMATCH[1]}"
            [[ "$_cur_bdf" == *:*:* ]] || _cur_bdf="0000:${_cur_bdf}"
        elif [[ "$_line" =~ Physical\ Slot:\ ([0-9]+) ]] && [ -n "$_cur_bdf" ]; then
            BRIDGE_SLOT["$_cur_bdf"]="${BASH_REMATCH[1]}"
            BRIDGE_NUMA["$_cur_bdf"]="${DEV_NUMA[$_cur_bdf]:--1}"
        fi
    done < <(lspci -v 2>/dev/null)

    # Determine which slotted bridges have endpoint children
    for _bdf in "${!BRIDGE_SLOT[@]}"; do
        _has_ep=0
        _check_endpoints() {
            local check="$1"
            local kids="${DEV_CHILDREN[$check]:-}"
            for k in $kids; do
                local kpath="/sys/bus/pci/devices/${k}/"
                if is_endpoint "$kpath"; then
                    _has_ep=1
                    return
                fi
                _check_endpoints "$k"
                [ "$_has_ep" = "1" ] && return
            done
        }
        _check_endpoints "$_bdf"
        if [ "$_has_ep" = "0" ]; then
            EMPTY_SLOTS+=("$_bdf")
        fi
    done
    unset _cur_bdf _bdf _has_ep
fi

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
    if [ -n "${GPU_COMPUTE_PART[$bdf]+x}" ]; then
        extras+=" ${DIM}[${GPU_COMPUTE_PART[$bdf]}/${GPU_MEMORY_PART[$bdf]:-?} (${GPU_COMPUTE_AVAIL[$bdf]:-?})]${RESET}"
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

    # Print each root subtree grouped by pcieRoot
    local root_list=("${!roots_to_show[@]}")
    IFS=$'\n' root_list=($(printf '%s\n' "${root_list[@]}" | sort))
    IFS=$' \t\n'

    echo -e "  ${DIM}PCIe topology:${RESET}"
    echo ""

    # Build sorted unique pcieRoot list and print grouped
    local prev_root=""
    for root_bdf in "${root_list[@]}"; do
        local pcie_root="${DEV_PCIE_ROOT_DOMAIN[$root_bdf]:-${DEV_PCIE_ROOT_DOMAIN[${root_bdf}]:-}}"
        # Fallback: derive from DEV_PARENT if not in lookup table
        if [ -z "$pcie_root" ]; then
            local _par="${DEV_PARENT[$root_bdf]:-}"
            if [[ "$_par" == root:* ]]; then
                pcie_root="${_par#root:}"
            fi
        fi
        if [ -n "$pcie_root" ] && [ "$pcie_root" != "$prev_root" ]; then
            local iommu_name="${ROOT_TO_IVHD[${pcie_root}]:-}"
            local root_label="pci${pcie_root}"
            [ -n "$iommu_name" ] && root_label+=" (${iommu_name})"
            echo -e "  ${DIM}pcieRoot: ${BOLD}${root_label}${RESET}"
            prev_root="$pcie_root"
        fi
        print_device "$root_bdf" "  " "0"
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
        if [ -n "${GPU_COMPUTE_PART[$bdf]+x}" ]; then
            extras+=" ${DIM}[${GPU_COMPUTE_PART[$bdf]}/${GPU_MEMORY_PART[$bdf]:-?} (${GPU_COMPUTE_AVAIL[$bdf]:-?})]${RESET}"
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

# ── Simple topology view (Socket → NUMA → pcieRoot → devices by type) ────────

print_simple_topology() {
    # Classify device type from PCI class + driver
    _dev_type() {
        local bdf="$1"
        local class_hex="${DEV_CLASS[$bdf]:-0x000000}"
        local class_int
        class_int=$(printf '%d' "$class_hex" 2>/dev/null) || { echo "other"; return; }
        local top=$(( class_int >> 16 ))
        local sub=$(( (class_int >> 8) & 0xFF ))

        case "$top" in
            18|3)
                local drv
                drv=$(get_driver "/sys/bus/pci/devices/${bdf}/")
                case "$drv" in
                    amdgpu|nvidia|i915|xe) echo "gpu" ;;
                    *) echo "accel" ;;
                esac
                ;;
            2)  echo "nic" ;;
            1)  [ "$sub" -eq 8 ] && echo "nvme" || echo "storage" ;;
            12) echo "usb" ;;
            4)  echo "multimedia" ;;
            *)  echo "other" ;;
        esac
    }

    # Short product label from lspci (truncated, strip redundant prefixes)
    _product_label() {
        local bdf="$1"
        local name
        name=$(short_name "$bdf")
        # Strip class prefix (e.g. "Processing accelerators: " or "Ethernet controller: ")
        name="${name#*: }"
        # Strip vendor prefixes for brevity
        name="${name#Advanced Micro Devices, Inc. }"
        name="${name#Mellanox Technologies }"
        name="${name#AMD Pensando Systems }"
        name="${name#NVIDIA Corporation }"
        name="${name#Intel Corporation }"
        name="${name#Broadcom Inc. and subsidiaries }"
        name="${name#Samsung Electronics Co Ltd }"
        # Strip [AMD] or [AMD/ATI] bracketed vendor tags
        name=$(echo "$name" | sed 's/\[AMD[^]]*\] //')
        # Strip "(rev XX)" suffix
        name="${name%%(*}"
        # Trim trailing whitespace
        name="${name%"${name##*[! ]}"}"
        echo "${name:0:45}"
    }

    # Determine socket ID for a NUMA node
    _socket_for_numa() {
        local nid="$1"
        local cpulist first_cpu
        cpulist=$(cat "/sys/devices/system/node/node${nid}/cpulist" 2>/dev/null || echo "")
        [ -z "$cpulist" ] && { echo "?"; return; }
        first_cpu=$(echo "$cpulist" | tr ',' '\n' | head -1 | tr '-' '\n' | head -1)
        cat "/sys/devices/system/cpu/cpu${first_cpu}/topology/physical_package_id" 2>/dev/null || echo "?"
    }

    # Collect all visible endpoints: "socket:numa:root" → list of "type|bdf|driver|product"
    declare -A _topo_groups=()     # key → newline-separated device entries
    declare -A _seen_sockets=()
    declare -A _seen_numas=()
    declare -A _seen_roots=()

    for bdf in "${!DEV_NUMA[@]}"; do
        local dev_path="/sys/bus/pci/devices/${bdf}/"
        is_endpoint "$dev_path" || continue
        if [ "$PCIE_ONLY" = "1" ] && ! has_link "$dev_path"; then continue; fi
        local bdf_class="${DEV_CLASS[$bdf]:-0x000000}"
        class_matches_filter "$bdf_class" || continue

        local numa="${DEV_NUMA[$bdf]}"
        local root_domain="${DEV_PCIE_ROOT_DOMAIN[$bdf]:-"-"}"
        local dtype
        dtype=$(_dev_type "$bdf")
        local drv
        drv=$(get_driver "$dev_path")
        local product
        product=$(_product_label "$bdf")
        local link
        link=$(get_link_info "$dev_path")

        # Skip no-NUMA devices — they appear in the "No NUMA Affinity" section
        [ "$numa" = "-1" ] && continue

        local socket
        socket=$(_socket_for_numa "$numa")

        local key="${socket}:${numa}:${root_domain}"
        _topo_groups["$key"]+="${dtype}|${bdf}|${drv}|${product}|${link}"$'\n'
        _seen_sockets["$socket"]=1
        _seen_numas["${socket}:${numa}"]=1
        _seen_roots["$key"]=1
    done

    # Print hierarchy
    local _sorted_sockets
    _sorted_sockets=$(printf '%s\n' "${!_seen_sockets[@]}" | sort)

    for sock in $_sorted_sockets; do
        echo -e "${BOLD}${CYAN}╔══ Socket ${sock} ══╗${RESET}"

        local _sorted_numas
        _sorted_numas=$(printf '%s\n' "${!_seen_numas[@]}" | grep "^${sock}:" | sort | sed "s/^${sock}://")

        for numa in $_sorted_numas; do
            local mem_total="" mem_label=""
            if [ "$numa" != "-1" ] && [ -f "/sys/devices/system/node/node${numa}/meminfo" ]; then
                mem_total=$(awk '/MemTotal/ {printf "%.0f GB", $4/1024/1024}' "/sys/devices/system/node/node${numa}/meminfo" 2>/dev/null)
                mem_label="  ${DIM}(${mem_total})${RESET}"
            fi
            echo -e "${BOLD}║ NUMA ${numa}${RESET}${mem_label}"

            local _sorted_roots
            _sorted_roots=$(printf '%s\n' "${!_seen_roots[@]}" | grep "^${sock}:${numa}:" | sort | sed "s/^${sock}:${numa}://")

            for root in $_sorted_roots; do
                local key="${sock}:${numa}:${root}"
                if [ "$root" != "-" ]; then
                    local _root_extra=""
                    # Add ivhd quadrant name if available
                    local _ivhd_name="${ROOT_TO_IVHD[$root]:-}"
                    [ -n "$_ivhd_name" ] && _root_extra+="${_ivhd_name}"
                    # Add SLIT distances to all NUMA nodes
                    if [ ${#SLIT_NODES[@]} -gt 0 ] && [ "$numa" != "-1" ]; then
                        local _dist_parts=()
                        for _dn in "${SLIT_NODES[@]}"; do
                            local _d="${SLIT_DIST[${numa}:${_dn}]:-?}"
                            if [ "$_dn" = "$numa" ]; then
                                _dist_parts+=("${BOLD}${_dn}=${_d}${RESET}${DIM}")
                            else
                                _dist_parts+=("${_dn}=${_d}")
                            fi
                        done
                        local _dist_str
                        _dist_str=$(IFS=','; echo "${_dist_parts[*]}" | sed 's/,/, /g')
                        if [ -n "$_root_extra" ]; then
                            _root_extra+=", dist: ${_dist_str}"
                        else
                            _root_extra="dist: ${_dist_str}"
                        fi
                    fi
                    if [ -n "$_root_extra" ]; then
                        echo -e "${DIM}║   pcieRoot: ${root}  (${_root_extra})${RESET}"
                    else
                        echo -e "${DIM}║   pcieRoot: ${root}${RESET}"
                    fi
                fi

                # Group entries by type, then by driver+product
                declare -A _type_bdfs=()   # "type::driver::product" → "bdf1 bdf2"
                declare -A _type_link=()   # same key → link info from first device
                while IFS='|' read -r dtype dbdf ddrv dprod dlink; do
                    [ -z "$dtype" ] && continue
                    local group_key="${dtype}::${ddrv}::${dprod}"
                    if [ -n "${_type_bdfs[$group_key]+x}" ]; then
                        _type_bdfs["$group_key"]+=" ${dbdf}"
                    else
                        _type_bdfs["$group_key"]="${dbdf}"
                        _type_link["$group_key"]="${dlink}"
                    fi
                done <<< "${_topo_groups[$key]:-}"

                # Print in type order: gpu, nic, nvme, storage, accel, other
                for dtype_order in gpu nic nvme storage accel usb multimedia other; do
                    local _gk_list
                    _gk_list=$(printf '%s\n' "${!_type_bdfs[@]}" 2>/dev/null | sort)
                    [ -z "$_gk_list" ] && continue
                    while IFS= read -r gk; do
                        [ -z "$gk" ] && continue
                        local gtype="${gk%%::*}"
                        [ "$gtype" != "$dtype_order" ] && continue

                        local grest="${gk#*::}"
                        local gdrv="${grest%%::*}"
                        local gprod="${grest#*::}"
                        local bdfs="${_type_bdfs[$gk]}"
                        local first_link="${_type_link[$gk]:-}"

                        local first_bdf="${bdfs%% *}"
                        local color
                        color=$(device_color "${DEV_CLASS[$first_bdf]:-0x000000}")

                        local bdf_count=0
                        for _ in $bdfs; do bdf_count=$((bdf_count + 1)); done

                        local bdf_str
                        if [ "$bdf_count" -le 3 ]; then
                            bdf_str=$(echo "$bdfs" | tr ' ' ', ')
                        else
                            bdf_str="${first_bdf} +$((bdf_count - 1)) more"
                        fi

                        local detail=""
                        [ -n "$gprod" ] && detail+="${gprod}"
                        [ -n "$gdrv" ] && [ "$gdrv" != "none" ] && detail+=", ${gdrv}"
                        [ -n "$first_link" ] && detail+=", ${first_link}"
                        if [ -n "${GPU_COMPUTE_PART[$first_bdf]+x}" ]; then
                            detail+=", ${GPU_COMPUTE_PART[$first_bdf]}/${GPU_MEMORY_PART[$first_bdf]:-?} (${GPU_COMPUTE_AVAIL[$first_bdf]:-?})"
                        fi

                        if [ -n "$detail" ]; then
                            echo -e "║     ${color}${gtype}:${RESET} ${bdf_str} ${DIM}(${detail})${RESET}"
                        else
                            echo -e "║     ${color}${gtype}:${RESET} ${bdf_str}"
                        fi
                    done <<< "$_gk_list"
                done
                unset _type_bdfs _type_link
            done
            echo "║"
        done
        echo -e "${CYAN}╚════════════════════╝${RESET}"
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

# ── Sub-NUMA clustering detection (AMD NPS / Intel SNC) ─────────────────────
# Inferred from NUMA-to-socket ratio. AMD uses NPS (Nodes Per Socket),
# Intel uses SNC (Sub-NUMA Clustering). Same mechanism, different labels.
NPS_MODE=""
IS_AMD=0
IS_INTEL=0
if grep -q 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
    IS_AMD=1
elif grep -q 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
    IS_INTEL=1
fi

if [ "$NUM_SOCKETS" -gt 0 ] && [ "$NUMA_NODES" -gt 0 ]; then
    _nodes_per_socket=$(( NUMA_NODES / NUM_SOCKETS ))
    if [ "$IS_AMD" = "1" ]; then
        case "$_nodes_per_socket" in
            1)  NPS_MODE="NPS1" ;;
            2)  NPS_MODE="NPS2" ;;
            4)  NPS_MODE="NPS4" ;;
            *)  # L3-as-NUMA or other sub-NUMA clustering
                _l3_count=$(find /sys/devices/system/cpu/cpu0/cache/ -maxdepth 1 -name 'index*' -exec sh -c \
                    'cat "$1/level" "$1/type" 2>/dev/null | tr "\n" " "' _ {} \; 2>/dev/null | grep -c '3 ')
                if [ "$_l3_count" -gt 0 ]; then
                    _total_l3=$(( $(lscpu 2>/dev/null | awk '/^L3 cache:/ {print $3}' | sed 's/[^0-9]//g') ))
                    _l3_per_cpu=$(( $(cat /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null | sed 's/K//') ))
                    if [ "${_l3_per_cpu:-0}" -gt 0 ] && [ "${_total_l3:-0}" -gt 0 ]; then
                        _l3_instances=$(( _total_l3 * 1024 / _l3_per_cpu ))
                        if [ "$NUMA_NODES" -eq "$_l3_instances" ]; then
                            NPS_MODE="L3-as-NUMA (${_nodes_per_socket} nodes/socket)"
                        fi
                    fi
                fi
                [ -z "$NPS_MODE" ] && NPS_MODE="NPS? (${_nodes_per_socket} nodes/socket)"
                unset _l3_count _total_l3 _l3_per_cpu _l3_instances
                ;;
        esac
    elif [ "$IS_INTEL" = "1" ]; then
        case "$_nodes_per_socket" in
            1)  NPS_MODE="SNC off" ;;
            2)  NPS_MODE="SNC-2" ;;
            4)  NPS_MODE="SNC-4" ;;
            *)  NPS_MODE="SNC? (${_nodes_per_socket} nodes/socket)" ;;
        esac
    else
        if [ "$_nodes_per_socket" -gt 1 ]; then
            NPS_MODE="${_nodes_per_socket} nodes/socket"
        fi
    fi
    unset _nodes_per_socket
fi

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

_total_slots=${#BRIDGE_SLOT[@]}
_empty_slots=${#EMPTY_SLOTS[@]}
_populated_slots=$(( _total_slots - _empty_slots ))
_slot_info=""
if [ "$_total_slots" -gt 0 ]; then
    _slot_info=", ${_populated_slots}/${_total_slots} PCIe slots populated"
fi

_nps_info=""
[ -n "$NPS_MODE" ] && _nps_info=", ${NPS_MODE}"

if [ "$NUM_SOCKETS" -gt 0 ]; then
    echo -e "${BOLD}NUMA Topology${RESET}  (${NUM_SOCKETS} socket(s), ${NUMA_NODES} node(s)${_nps_info}${_slot_info})"
else
    echo -e "${BOLD}NUMA Topology${RESET}  (${NUMA_NODES} node(s)${_slot_info})"
fi
unset _nps_info
unset _total_slots _empty_slots _populated_slots _slot_info
echo ""

if [ "$SIMPLE" = "1" ]; then
    print_simple_topology
else

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

        # Show empty physical slots on this NUMA node
        _empty_on_node=()
        for _ebdf in "${EMPTY_SLOTS[@]}"; do
            [ "${BRIDGE_NUMA[$_ebdf]:--1}" = "$node_id" ] || continue
            _empty_on_node+=("$_ebdf")
        done
        if [ ${#_empty_on_node[@]} -gt 0 ]; then
            echo ""
            echo -e "  ${DIM}Empty slots:${RESET}"
            for _ebdf in "${_empty_on_node[@]}"; do
                _slot="${BRIDGE_SLOT[$_ebdf]}"
                _root_domain=$(readlink "/sys/bus/pci/devices/${_ebdf}" 2>/dev/null | sed 's|.*\(pci[^/]*\)/.*|\1|')
                echo -e "  ${DIM}└── Slot ${_slot}  (${_ebdf}, root ${_root_domain:-unknown})${RESET}"
            done
        fi
        echo ""
    fi
done

fi  # end if [ "$SIMPLE" != "1" ]

# ── IOD Quadrant / IOMMU Instance Summary ────────────────────────────────────

if [ "$IVHD_AVAILABLE" = "1" ] && [ ${#IVHD_LIST[@]} -gt 0 ]; then
    # Count GPUs across all ivhd instances
    _total_ivhd_gpus=0
    for _iv in "${IVHD_LIST[@]}"; do
        for _g in ${IVHD_GPUS[$_iv]:-}; do
            _total_ivhd_gpus=$(( _total_ivhd_gpus + 1 ))
        done
    done

    _gpu_ratio=""
    _unit_label="unit"
    if [ "$IOMMU_TYPE" = "ivhd" ]; then
        _unit_label="quadrant"
    fi
    if [ "$_total_ivhd_gpus" -gt 0 ] && [ ${#IVHD_LIST[@]} -gt 0 ]; then
        _gpus_per=$(( _total_ivhd_gpus / ${#IVHD_LIST[@]} ))
        if [ "$_gpus_per" -le 1 ]; then
            _gpu_ratio=", 1 GPU per ${_unit_label}"
        else
            _gpu_ratio=", ${_gpus_per} GPUs per ${_unit_label}"
        fi
    fi

    _section_title="IOMMU Instance Mapping"
    [ "$IOMMU_TYPE" = "ivhd" ] && _section_title="IOD Quadrant Mapping"
    [ "$IOMMU_TYPE" = "dmar" ] && _section_title="DMAR Unit Mapping"

    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║  ${_section_title}  (${#IVHD_LIST[@]} IOMMU instances${_gpu_ratio})${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"

    if [ -n "$NPS_MODE" ]; then
        _gpus_per_numa=$(( _total_ivhd_gpus / NUMA_NODES ))
        echo -e "  ${DIM}Current: ${NPS_MODE} (${_gpus_per_numa} GPU(s) per NUMA node)${RESET}"
        if [ "$IOMMU_TYPE" = "ivhd" ] && [ "$NPS_MODE" != "NPS4" ] && [ "$_total_ivhd_gpus" -gt 0 ]; then
            echo -e "  ${DIM}NPS4 would give: 1 GPU per NUMA node (= pcieRoot granularity)${RESET}"
        fi
        echo ""
    fi

    for _iv in "${IVHD_LIST[@]}"; do
        _roots="${IVHD_ROOTS[$_iv]:-}"
        _roots="${_roots# }"
        _roots_sorted=$(echo "$_roots" | tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

        # Determine socket and NUMA node from devices in this ivhd
        _iv_numa=""
        _iv_socket=""
        for _g in ${IVHD_GPUS[$_iv]:-}; do
            _iv_numa="${DEV_NUMA[$_g]:--1}"
            [ "$_iv_numa" != "-1" ] && break
            _iv_numa=""
        done
        if [ -z "$_iv_numa" ]; then
            for _n in ${IVHD_NICS[$_iv]:-}; do
                _iv_numa="${DEV_NUMA[$_n]:--1}"
                [ "$_iv_numa" != "-1" ] && break
                _iv_numa=""
            done
        fi
        if [ -z "$_iv_numa" ]; then
            for _v in ${IVHD_NVME[$_iv]:-}; do
                _iv_numa="${DEV_NUMA[$_v]:--1}"
                [ "$_iv_numa" != "-1" ] && break
                _iv_numa=""
            done
        fi
        if [ -z "$_iv_numa" ] && [ -d "/sys/class/iommu/${_iv}/devices" ]; then
            for _dev_link in "/sys/class/iommu/${_iv}/devices/"*/; do
                _dbdf=$(basename "$_dev_link")
                [ "$_dbdf" = "*" ] && continue
                _dn="${DEV_NUMA[$_dbdf]:--1}"
                if [ "$_dn" != "-1" ]; then
                    _iv_numa="$_dn"
                    break
                fi
            done
        fi
        if [ -n "$_iv_numa" ] && [ "$_iv_numa" != "-1" ]; then
            _first_cpu=$(cat "/sys/devices/system/node/node${_iv_numa}/cpulist" 2>/dev/null | tr ',' '\n' | head -1 | tr '-' '\n' | head -1)
            if [ -n "$_first_cpu" ]; then
                _iv_socket=$(cat "/sys/devices/system/cpu/cpu${_first_cpu}/topology/physical_package_id" 2>/dev/null)
            fi
        fi

        _loc=""
        if [ -n "$_iv_socket" ]; then
            _loc="Socket ${_iv_socket}, NUMA ${_iv_numa}"
        elif [ -n "$_iv_numa" ] && [ "$_iv_numa" != "-1" ]; then
            _loc="NUMA ${_iv_numa}"
        fi

        _line="  ${BOLD}${_iv}${RESET}"
        [ -n "$_loc" ] && _line+="  ${DIM}${_loc}${RESET}"
        echo -e "$_line"

        # Collect all classified devices with their pcieRoot
        declare -A _root_gpus=()
        declare -A _root_nics=()
        declare -A _root_nvme=()
        declare -A _roots_seen=()

        for _g in ${IVHD_GPUS[$_iv]:-}; do
            _rb="${DEV_PCIE_ROOT[$_g]:-?}"
            _root_gpus["$_rb"]+=" $_g"
            _roots_seen["$_rb"]=1
        done
        for _n in ${IVHD_NICS[$_iv]:-}; do
            _rb="${DEV_PCIE_ROOT[$_n]:-?}"
            _root_nics["$_rb"]+=" $_n"
            _roots_seen["$_rb"]=1
        done
        for _v in ${IVHD_NVME[$_iv]:-}; do
            _rb="${DEV_PCIE_ROOT[$_v]:-?}"
            _root_nvme["$_rb"]+=" $_v"
            _roots_seen["$_rb"]=1
        done

        # Also include roots with no classified devices
        for _rb in $(echo "$_roots" | tr ' ' '\n' | sort); do
            _roots_seen["$_rb"]=1
        done

        # Print each pcieRoot within this quadrant
        _sorted_roots=$(printf '%s\n' "${!_roots_seen[@]}" | sort)
        for _rb in $_sorted_roots; do
            # Get the domain prefix from this ivhd's devices
            _domain=""
            for _g in ${IVHD_GPUS[$_iv]:-}; do
                _domain="${_g%%:*}"
                break
            done
            [ -z "$_domain" ] && for _n in ${IVHD_NICS[$_iv]:-}; do
                _domain="${_n%%:*}"
                break
            done
            [ -z "$_domain" ] && _domain="0000"

            _rline="    ${DIM}pcieRoot ${_domain}:${_rb}${RESET}"
            _has_devs=0

            _gpu_list=""
            for _g in ${_root_gpus[$_rb]:-}; do
                [ -n "$_gpu_list" ] && _gpu_list+=", "
                _gpu_list+="$_g"
                _has_devs=1
            done
            [ -n "$_gpu_list" ] && _rline+="  ${BOLD}${YELLOW}GPU:${RESET} ${_gpu_list}"

            _nic_list=""
            for _n in ${_root_nics[$_rb]:-}; do
                [ -n "$_nic_list" ] && _nic_list+=", "
                _nic_list+="$_n"
                _has_devs=1
            done
            [ -n "$_nic_list" ] && _rline+="  ${BOLD}${MAGENTA}NIC:${RESET} ${_nic_list}"

            _nvme_list=""
            for _v in ${_root_nvme[$_rb]:-}; do
                [ -n "$_nvme_list" ] && _nvme_list+=", "
                _nvme_list+="$_v"
                _has_devs=1
            done
            [ -n "$_nvme_list" ] && _rline+="  ${BOLD}${BLUE}NVMe:${RESET} ${_nvme_list}"

            # Only print roots that have classified devices (skip infra-only roots)
            [ "$_has_devs" = "1" ] && echo -e "$_rline"
        done

        unset _root_gpus _root_nics _root_nvme _roots_seen
    done
    echo ""
    unset _iv _roots _roots_sorted _line _gpu_list _nic_list _nvme_list _rline
    unset _g _n _v _rb _domain _has_devs _sorted_roots
    unset _total_ivhd_gpus _gpu_ratio _gpus_per _gpus_per_numa
    unset _iv_numa _iv_socket _first_cpu _loc
fi

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

# NUMA Topology Capture — Fedora 44 Live ISO

A minimal Fedora 44 live ISO that boots on a server, automatically runs
`numa-topology.sh`, and saves the output. Use it to quickly capture NUMA/PCIe
topology from bare-metal servers without installing anything.

## What it does

On boot, the ISO:
1. Auto-logins as root (no password prompt on console)
2. Runs `numa-topology.sh` and displays output on the console
3. Saves two files to `/root/`:
   - `numa-topology-<system-model>-<timestamp>.txt` — full topology tree
   - `numa-topology-accelerators-<system-model>-<timestamp>.txt` — accelerators-only flat view
4. Drops you to a root shell for interactive exploration

The system model comes from DMI data (`dmidecode -s system-product-name`), so
output files are named like `numa-topology-PowerEdge-R760xa-20260429-143022.txt`.

## Prerequisites

Install build tools on your Fedora workstation:

```bash
sudo dnf install lorax livecd-tools pykickstart
```

## Build the ISO

```bash
cd testing/live-iso
sudo ./build-live-iso.sh
```

This produces `output/numa-topology-live.iso`.

## Boot methods

### USB stick (with persistent writable overlay)

This is the recommended method — the overlay makes the live filesystem writable,
so the topology output files persist on the USB and can be retrieved later.

```bash
# Write ISO to USB with 512MB writable overlay
sudo livecd-iso-to-disk --overlay-size-mb 512 output/numa-topology-live.iso /dev/sdX
```

**To retrieve output after booting the server:**
1. Plug the USB into your laptop
2. Mount the USB partition
3. Files are in `/root/numa-topology-*.txt`

### iDRAC / BMC virtual media

Mount the ISO via iDRAC virtual media and boot from it. The topology output
prints to the console, so capture it from the iDRAC virtual console session
(copy/paste or screenshot). The output files won't persist since the ISO is
read-only when mounted this way.

## Interactive use

After the auto-capture completes, you have a root shell with these tools:

```bash
numa-topology.sh              # Full NUMA + PCIe topology tree
numa-topology.sh -a           # Accelerators (GPUs) only
numa-topology.sh -a -f        # Accelerators flat list (no tree)
numa-topology.sh -n           # Network devices only
numa-topology.sh -s           # Storage devices only
numa-topology.sh --help       # All options

lspci -tv                     # Raw PCI tree
dmidecode -t memory           # DIMM details
lscpu                         # CPU topology
numactl --hardware            # NUMA distances
```

## Files

| File | Purpose |
|------|---------|
| `numa-topology-live.ks` | Kickstart — defines packages, embeds the script, creates the systemd auto-run service |
| `build-live-iso.sh` | Build script — validates kickstart, copies script, runs `livemedia-creator` |
| `../scripts/numa-topology.sh` | The topology script that gets embedded in the ISO |

## Configuration

- **Root password:** `topology` (for interactive login if needed)
- **SELinux:** permissive (avoids interference with sysfs reads)
- **Firewall:** disabled
- **Image size:** ~4GB (minimal Fedora core + pciutils + dmidecode)

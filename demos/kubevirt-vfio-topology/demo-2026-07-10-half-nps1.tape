# KubeVirt VFIO Passthrough with DRA Topology Coordinator (NPS1)
# Run: vhs demo.tape
# Pre-req: kubectl apply -f demo-vm-half.yaml (VM must be Running before recording)

Output demo.gif
Output demo.mp4

Set Shell "bash"
Set FontSize 14
Set Width 1800
Set Height 1200
Set Padding 10
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Hide
Type "export PATH=$HOME/devel/dra-topology-aware-co-placement/testing/scripts:$PATH"
Enter
Type "export DEMO=$HOME/devel/dra-topology-aware-co-placement/demos/kubevirt-vfio-topology"
Enter
Sleep 1s
Type "clear"
Enter
Sleep 0.5s
Show

# 1. Host topology — Socket/NUMA/PCIeRoot with GPU VFs and NIC VFs
Type "dra-verify.sh topology | more"
Enter
Sleep 8s
Type " "
Sleep 8s

# 2. Hardware summary — all DRA drivers and devices
Type "clear"
Enter
Sleep 0.5s
Type "dra-verify.sh slices"
Enter
Sleep 8s

# 3. DeviceClasses — partition and pairing options
Type "clear"
Enter
Sleep 0.5s
Type "dra-verify.sh deviceclasses | more"
Enter
Sleep 10s
Type " "
Sleep 10s

# 4. Show the VM manifest — ResourceClaimTemplate + VMI in one file
Type "clear"
Enter
Sleep 0.5s
Type "cat $DEMO/demo-vm-half.yaml"
Enter
Sleep 8s

# 5. Show VM running
Type "clear"
Enter
Sleep 0.5s
Type "kubectl get vm,vmi"
Enter
Sleep 5s

# 6. Show claims — per-pair pcieRoot + global numaNode alignment
Type "clear"
Enter
Sleep 0.5s
Type "dra-verify.sh claims | more"
Enter
Sleep 10s
Type " "
Sleep 10s

# 7. SSH into guest and show topology — 4 GPUs + 4 NICs on one NUMA
Type "clear"
Enter
Sleep 0.5s
Type "sshpass -p fedora ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null fedora@$(kubectl get vmi demo-vm-half -o jsonpath='{.status.interfaces[0].ipAddress}') 'bash -s' < $HOME/devel/dra-topology-aware-co-placement/testing/scripts/hw-topology.sh | more"
Enter
Sleep 8s
Type " "
Sleep 8s

Sleep 2s

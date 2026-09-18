# KubeVirt multi-GPU/NIC DRA topology demo
# Run: vhs demo.tape
# Pre-req: apply demo-vm.yaml and wait for the VM to be Running
# The tape intentionally uses only the existing topology and DRA verification scripts.

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
Type "export ROOT=$HOME/devel/dra-topology-aware-co-placement"
Enter
Type "export DEMO=$ROOT/demos/kubevirt-host-guest-topology"
Enter
Type "export PATH=$ROOT/testing/scripts:$PATH"
Enter
Type "export VM=amd-host-guest-topology-dual-pair"
Enter
Sleep 1s
Type "clear"
Enter
Sleep 0.5s
Show

# 1. Physical host topology — two GPU/NIC PCIe-root pairs.
Type "hw-topology.sh --simple -p | more"
Enter
Sleep 35s
Type " "
Sleep 8s

# 2. DRA topology — the driver-published view of the same host.
Type "clear"
Enter
Sleep 0.5s
Type "dra-verify.sh topology"
Enter
Sleep 8s
Type " "
Sleep 8s

# 3. ResourceSlices — AMD GPU, SR-IOV NIC, CPU, and memory.
Type "clear"
Enter
Sleep 0.5s
Type "dra-verify.sh slices"
Enter
Sleep 8s
Type " "
Sleep 8s

# 3. The dual-pair ResourceClaimTemplate and VirtualMachine.
Type "clear"
Enter
Sleep 0.5s
Type "cat $DEMO/demo-vm.yaml | more"
Enter
Sleep 8s

# 4. Running VM and VMI.
Type "clear"
Enter
Sleep 0.5s
Type "kubectl get vm,vmi $VM -o wide"
Enter
Sleep 6s

# 5. Claim allocation and pair-local PCIe-root/NUMA alignment.
Type "clear"
Enter
Sleep 0.5s
Type "dra-verify.sh claims | more"
Enter
Sleep 10s
Type " "
Sleep 10s

# 6. Guest DRA topology and PCIe topology.
Type "clear"
Enter
Sleep 0.5s
Type "DRA_GUEST_USER=jhull DRA_GUEST_SSH_KEY=~/.ssh/kubevirt-gpu-vm-ed25519 dra-verify.sh guest $VM | more"
Enter
Sleep 10s
Type " "
Sleep 10s

Type "clear"
Enter
Sleep 0.5s
Type "ssh -i ~/.ssh/kubevirt-gpu-vm-ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null jhull@$(kubectl get vmi $VM -o jsonpath='{.status.interfaces[0].ipAddress}') 'bash -s -- --simple' < $ROOT/testing/scripts/hw-topology.sh | more"
Enter
Sleep 8s
Type " "
Sleep 8s

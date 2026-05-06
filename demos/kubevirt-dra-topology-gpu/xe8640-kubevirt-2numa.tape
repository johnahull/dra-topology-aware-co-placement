# XE8640 KubeVirt Multi-NUMA VM with DRA
# Run: vhs xe8640-kubevirt-2numa.tape

Output xe8640-kubevirt-2numa.gif

Set Shell "bash"
Set FontSize 14
Set Width 1400
Set Height 1200
Set Padding 10
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Hide
Type "ssh jhull@10.6.62.51"
Enter
Sleep 5s
Type "cd /home/jhull/dra-topology-aware-co-placement/testing/scripts"
Enter
Sleep 1s
Type "clear"
Enter
Sleep 0.5s
Show

# 1. Host NUMA topology
Type "sh numa-topology.sh -p -f -a | more"
Enter
Sleep 30s
Sleep 3s
Type " "
Sleep 3s
Type " "
Sleep 3s
Type " "
Sleep 3s

# 2. DRA topology verification (verbose)
Type "sh dra-verify.sh topology -v"
Enter
Sleep 10s

# 3. ResourceSlices summary
Type "sh dra-verify.sh slices"
Enter
Sleep 10s

# 4. Device classes
Type "sh dra-verify.sh deviceclasses"
Enter
Sleep 10s

# 5. Show running VM
Type "kubectl get vm"
Enter
Sleep 5s

# 6. Show VMI
Type "kubectl get vmi"
Enter
Sleep 5s

# 7. DRA claims — what the VM got
Type "sh dra-verify.sh claims"
Enter
Sleep 10s

# 8. Show the VM manifest — how it was defined
Type "more ../../demos/kubevirt-dra-topology-gpu/demo-vm-2numa.yaml"
Enter
Sleep 3s
Type " "
Sleep 3s
Type " "
Sleep 3s
Type " "
Sleep 3s

# 9. SSH into VM and run numa-topology
Type "sshpass -p fedora ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null fedora@192.168.29.181"
Enter
Sleep 5s
Type "cd /home/fedora/dra-topology-aware-co-placement/testing/scripts && bash numa-topology.sh -p -f -a"
Enter
Sleep 30s

# 10. Exit VM
Type "exit"
Enter
Sleep 1s

Sleep 2s

# XE8640 DRA Topology Verification
# Run: vhs xe8640-dra-verify.tape

Output xe8640-dra-verify.gif

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

# 1. NUMA topology with PCIe flat accelerators view
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

# 5. Claims (before demo)
Type "sh dra-verify.sh claims"
Enter
Sleep 10s

# 6. Show the demo manifest
Type "more ../../demos/topology-coordinator-basic/demo-half-and-quarters.yaml"
Enter
Sleep 3s
Type " "
Sleep 3s
Type " "
Sleep 3s
Type " "
Sleep 3s

# 7. Apply the demo
Type "kubectl apply -f ../../demos/topology-coordinator-basic/demo-half-and-quarters.yaml"
Enter
Sleep 5s

# 8. Check pods
Type "kubectl get pods"
Enter
Sleep 5s

# 9. Check resource claims
Type "kubectl get resourceclaims"
Enter
Sleep 5s

# 10. Claims (after demo)
Type "sh dra-verify.sh claims"
Enter
Sleep 10s

# 11. Device classes (after demo)
Type "sh dra-verify.sh deviceclasses"
Enter
Sleep 10s

Sleep 2s

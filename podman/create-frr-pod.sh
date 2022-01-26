#!/usr/bin/env bash 
set -e

NUMBER_OF_FRR_INSTANCE=5
BM_NETWORK_PREF="192.168.220"
CLUSTER_ASN=65001

echo "------------------DELETE OLD FRR PODS------------------"
old_pods=$(podman ps -a | grep frr | awk '{print $1}' | xargs)

if [ "$old_pods" != "" ]; then
echo "deleting pod $old_pods"	
podman stop $old_pods	
podman rm $old_pods
fi

echo "------------------GET OCP NODES FROM CLUSTER-----------"

export KUBECONFIG="/home/kni/clusterconfigs/auth/kubeconfig"

NODE_LIST=$(oc get nodes --no-headers -o wide | grep worker | grep -iv worker-lb | grep -iv worker-rt | awk '{print $6}')

echo "------------------COPY PODMAN NETWORK CONFIG-----------"
cp 87-podman-bridge.conflist /etc/cni/net.d/87-podman-bridge.conflist

for i in $(seq 1 $NUMBER_OF_FRR_INSTANCE)
do
POD_IP="$BM_NETWORK_PREF."$((100+$i))

echo "------------------COPY DAEMON CONFIGS-----POD-$i-------"
rm -rf /root/frr-pod-$i 
mkdir /root/frr-pod-$i
cp daemons /root/frr-pod-$i
cp vtysh.conf /root/frr-pod-$i

echo "------------------CREATE FRR CONFIGS------POD-$i-------"

cat <<EOT >> /root/frr-pod-$i/frr.conf
frr version 8.2-dev_git
frr defaults traditional

log file /tmp/frr.log debugging
log timestamp precision 3

route-map RMAP permit 10
set ipv6 next-hop prefer-global

router bgp $(($CLUSTER_ASN+$i))
  bgp router-id $POD_IP
EOT

for node in $NODE_LIST
do
cat <<EOT >> /root/frr-pod-$i/frr.conf
  neighbor $node remote-as $CLUSTER_ASN
  neighbor $node update-source $POD_IP
  neighbor $node password test
  neighbor $node bfd profile echo
EOT
done 

cat <<EOT >> /root/frr-pod-$i/frr.conf
  address-family ipv4 unicast
EOT

for node in $NODE_LIST
do
cat <<EOT >> /root/frr-pod-$i/frr.conf
    neighbor $node next-hop-self
    neighbor $node activate
EOT
done

cat <<EOT >> /root/frr-pod-$i/frr.conf
  exit-address-family
!

bfd
  profile echo
    detect-multiplier 37
    transmit-interval 35
    receive-interval 35
    echo-mode
    minimum-ttl 10
  !
!
EOT

# create FRR podman containers
echo "------------------CREATE FRR PODS---------POD-$i-------"

podman run --name frr-pod-$i --privileged --ip $POD_IP -v /root/frr-pod-$i/:/etc/frr/ -d quay.io/frrouting/frr
sleep 2

echo "------------------SHOW BGP SUMMARY--------POD-$i-------"
podman exec frr-pod-$i vtysh -c "show bgp summary"

echo "------------------FINISHED FRR POD--------POD-$i-------"
echo "-------------------------------------------------------"

done
echo "------------------FINISHED CREATING ALL FRR PODS-------"

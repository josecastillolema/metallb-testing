#!/usr/bin/env bash 
set -e

NUMBER_OF_FRR_INSTANCE=5
BM_NETWORK_PREF="192.168.220"
BM_NETWORK_PREF_END="192.168.223"
CLUSTER_ASN=65001
BFD_PROFILE="bfdprofilefull"
RACK_ID="e17"

echo "------------------DELETE OLD FRR PODS------------------"
old_pods=$(podman ps -a | grep frr | awk '{print $1}' | xargs)

if [ "$old_pods" != "" ]; then
echo "deleting pod $old_pods"	
podman stop $old_pods	
podman rm $old_pods
fi

echo "------------------GET OCP NODES FROM CLUSTER-----------"

export KUBECONFIG="/home/kni/clusterconfigs/auth/kubeconfig"
HOST_LIST=$(oc get bmh -A -o wide | grep $RACK_ID | awk '{print$2}')
NODE_LIST=$(oc get nodes $HOST_LIST --no-headers -o wide | grep worker | grep -iv worker-lb | grep -iv worker-rt | grep -iv worker-spk | awk '{print $6}')

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
EOT

if [ "$BFD_PROFILE" != "" ]; then
cat <<EOT >> /root/frr-pod-$i/frr.conf
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
fi

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
echo "------------------PAUSE FOR A FEW SECONDS--------------"
sleep 5

echo "------------------CREATE METALLB CUSTOM RESOURCES------"
oc label ns metallb-system openshift.io/cluster-monitoring=true --overwrite=true

export BM_NETWORK_PREF=$BM_NETWORK_PREF
export BM_NETWORK_PREF_END=$BM_NETWORK_PREF_END
envsubst < metallb-cr.yaml | oc apply -f -

for k in $(seq 1 $NUMBER_OF_FRR_INSTANCE)
do
PEER_IP="$BM_NETWORK_PREF."$((100+$k))
cat << EOF | oc apply -f -
---
apiVersion: metallb.io/v1beta1
kind: BGPPeer
metadata:
  name: peer-$(($CLUSTER_ASN+$k))
  namespace: metallb-system
spec:
  peerAddress: $PEER_IP
  peerASN: $(($CLUSTER_ASN+$k))
  myASN: $CLUSTER_ASN
  password: test
  bfdProfile: $BFD_PROFILE
EOF
done

echo "------------------LISTS METALLB CUSTOM RESOURCES-------"
oc get addresspool -A
oc get bgppeers -A
echo "-------------------------------------------------------"

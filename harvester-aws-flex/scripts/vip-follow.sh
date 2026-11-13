#!/usr/bin/env bash
# A VPC ignores gratuitous ARP, so the VIP only works on the node whose ENI
# carries it as a secondary IP (node 1 at install). If kube-vip leadership
# moved, move the secondary IP to the leader's ENI.
source "$(dirname "$0")/lib.sh"
need aws kubectl
load_config
LEADER=$(hkubectl -n harvester-system get lease plndr-svcs-lock -o jsonpath='{.spec.holderIdentity}') || die "cannot read kube-vip lease"
for n in 1 2 3; do [ "$(node_name "$n")" = "$LEADER" ] && L=$n; done
[ -n "${L:-}" ] || die "leader '$LEADER' is not one of this cluster's nodes"
ENI_VAR="NODE${L}_ENI"; ENI=${!ENI_VAR:-$(aws ec2 describe-instances --instance-ids "$(node_id "$L")" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)}
CUR=$(aws ec2 describe-network-interfaces --filters "Name=addresses.private-ip-address,Values=$VIP" "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[0].NetworkInterfaceId' --output text)
if [ "$CUR" = "$ENI" ]; then ok "VIP $VIP already on $LEADER ($ENI)"; exit 0; fi
aws ec2 assign-private-ip-addresses --network-interface-id "$ENI" --private-ip-addresses "$VIP" --allow-reassignment
ok "moved VIP $VIP from $CUR to $LEADER ($ENI)"

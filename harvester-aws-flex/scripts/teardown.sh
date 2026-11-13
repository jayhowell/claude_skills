#!/usr/bin/env bash
# Destroys ONE cluster's AWS resources (everything tagged Project=$CLUSTER_NAME
# that this skill created). Asks you to type the cluster name.
#   usage: teardown.sh [--delete-ami] [--remove-from-rancher]
#   --delete-ami           also deregister the iPXE AMI + snapshot this cluster built
#                          (skip it if other clusters reuse the AMI)
#   --remove-from-rancher  also delete the cluster from Rancher
source "$(dirname "$0")/lib.sh"
need aws
load_config
DEL_AMI=false; DEL_RANCHER=false
for a in "$@"; do case $a in --delete-ami) DEL_AMI=true;; --remove-from-rancher) DEL_RANCHER=true;; *) die "unknown option $a";; esac; done

IDS=$(aws ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$TAG_VAL" \
  Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
echo "This will permanently delete, in $AWS_REGION:"
echo "  instances: ${IDS:-none} (and their EBS volumes, including all Longhorn data)"
echo "  security group: ${SG_ID:-none}   bucket: ${BUCKET:-none}"
[ "$DEL_AMI" = true ] && echo "  AMI: ${AMI_ID:-none} snapshot: ${AMI_SNAPSHOT_ID:-none}"
[ "$DEL_RANCHER" = true ] && echo "  Rancher cluster: $CLUSTER_NAME"
read -r -p "Type the cluster name ($CLUSTER_NAME) to confirm: " ans
[ "$ans" = "$CLUSTER_NAME" ] || die "aborted"

if [ "$DEL_RANCHER" = true ]; then
  rkubectl -n fleet-default delete clusters.provisioning.cattle.io "$CLUSTER_NAME" --wait=false 2>/dev/null && ok "removed from Rancher" || warn "not found in Rancher"
fi
if [ -n "$IDS" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  log "terminating instances..."
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $IDS
  ok "instances terminated"
fi
if [ -n "${SG_ID:-}" ]; then
  for _ in $(seq 1 20); do aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null && break; sleep 15; done
  ok "security group deleted"; state_unset SG_ID
fi
if [ -n "${BUCKET:-}" ]; then
  aws s3 rm "s3://$BUCKET" --recursive --quiet 2>/dev/null || true
  aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || true; state_unset BUCKET; ok "bucket deleted"
fi
if [ "$DEL_AMI" = true ] && [ -n "${AMI_ID:-}" ] && [ -z "${IPXE_AMI_ID:-}" ]; then
  aws ec2 deregister-image --image-id "$AMI_ID" && ok "AMI $AMI_ID deregistered"
  [ -n "${AMI_SNAPSHOT_ID:-}" ] && aws ec2 delete-snapshot --snapshot-id "$AMI_SNAPSHOT_ID" && ok "snapshot deleted"
  state_unset AMI_ID; state_unset AMI_SNAPSHOT_ID
fi
for n in 1 2 3; do state_unset "NODE${n}_ID"; state_unset "NODE${n}_ENI"; state_unset "NODE${n}_PUBLIC_IP"; done
ok "teardown complete. Local state kept in $STATE_DIR (delete it manually if no longer needed)"

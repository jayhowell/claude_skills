#!/usr/bin/env bash
# Creates the cluster security group, the private install-config bucket and
# the Harvester password/token. Idempotent: reuses what's already in state.env.
source "$(dirname "$0")/lib.sh"
need aws openssl
load_config
[ -n "${VPC_ID:-}" ] && [ -n "${ADMIN_CIDR:-}" ] || die "run 00-preflight.sh first"

if [ -z "${SG_ID:-}" ]; then
  log "creating security group $CLUSTER_NAME"
  SG_ID=$(aws ec2 create-security-group --group-name "$CLUSTER_NAME" --description "Harvester cluster $CLUSTER_NAME" \
    --vpc-id "$VPC_ID" --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$CLUSTER_NAME},{Key=$TAG_KEY,Value=$TAG_VAL}]" \
    --query GroupId --output text)
  # All traffic between nodes (etcd, kubelet, VXLAN, Longhorn, RKE2 supervisor,
  # VIP); admin access to UI/SSH/K8s API only from ADMIN_CIDR.
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$SG_ID,Description=intra-cluster}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$ADMIN_CIDR,Description=admin-ui}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$ADMIN_CIDR,Description=admin-ssh}]" \
    "IpProtocol=tcp,FromPort=6443,ToPort=6443,IpRanges=[{CidrIp=$ADMIN_CIDR,Description=admin-k8s}]" >/dev/null
  state_set SG_ID "$SG_ID"
fi
ok "security group $SG_ID"

if [ -z "${BUCKET:-}" ]; then
  BUCKET="$CLUSTER_NAME-cfg-$(openssl rand -hex 4)"
  log "creating install-config bucket $BUCKET"
  if [ "$AWS_REGION" = us-east-1 ]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VAL}]"
  state_set BUCKET "$BUCKET"
fi
ok "bucket $BUCKET (objects readable only from node public IPs; deleted by 07-cleanup-install-configs.sh)"

if [ ! -f "$STATE_DIR/secrets.env" ]; then
  ( umask 077
    printf 'HARVESTER_PASSWORD=%s\nHARVESTER_TOKEN=%s\n' \
      "$(openssl rand -base64 18 | tr -d '/+=')" "$(openssl rand -hex 24)" > "$STATE_DIR/secrets.env" )
fi
ok "node password (user 'rancher') and cluster token in $STATE_DIR/secrets.env"

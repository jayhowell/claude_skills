#!/usr/bin/env bash
# Read-only checks before spending money. Resolves subnet/VPC/admin CIDR into
# state.env. Exits non-zero on anything that would break the build.
source "$(dirname "$0")/lib.sh"
need aws jq curl kubectl openssl ssh ssh-keygen base64
load_config

log "AWS identity"
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
  || die "AWS credentials are missing or expired (try: aws sso login)"
ok "$(aws sts get-caller-identity --query Arn --output text)"

log "Instance type $INSTANCE_TYPE"
read -r VCPU MEM MODES FEATS <<<"$(aws ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" \
  --query 'InstanceTypes[0].[VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB,join(`,`,SupportedBootModes),join(`,`,ProcessorInfo.SupportedFeatures)]' \
  --output text)" || die "unknown instance type $INSTANCE_TYPE"
[[ ",$MODES," == *",uefi,"* ]] || die "$INSTANCE_TYPE does not support UEFI (boot modes: $MODES). Harvester >= v1.8 requires UEFI."
[[ ",$FEATS," == *",nested-virtualization,"* ]] || die "$INSTANCE_TYPE does not support nested virtualization"
if (( VCPU < 8 || MEM < 32768 )); then
  [ "${ALLOW_UNDERSIZED:-}" = true ] || die "$INSTANCE_TYPE has $VCPU vCPU / $((MEM / 1024)) GiB; Harvester needs >= 8 vCPU / 32 GiB (set ALLOW_UNDERSIZED=true to force)"
  warn "$INSTANCE_TYPE is below Harvester's minimum; expect failures"
fi
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=$INSTANCE_TYPE" "Name=location,Values=$AZ" \
  --query 'InstanceTypeOfferings[0].InstanceType' --output text | grep -q "$INSTANCE_TYPE" \
  || die "$INSTANCE_TYPE is not offered in $AZ"
ok "$VCPU vCPU / $((MEM / 1024)) GiB, UEFI + nested virtualization, offered in $AZ"

log "Subnet and IPs"
if [ -z "${SUBNET_ID:-}" ]; then
  SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availability-zone,Values=$AZ" Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)
  [ "$SUBNET_ID" != None ] || die "no default subnet in $AZ; set SUBNET_ID"
fi
read -r VPC_ID SUBNET_CIDR SUBNET_AZ MAPPUB <<<"$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].[VpcId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' --output text)"
[ "$SUBNET_AZ" = "$AZ" ] || die "subnet $SUBNET_ID is in $SUBNET_AZ, not $AZ"
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' --output text | grep -q '^igw-' \
  || aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" Name=association.main,Values=true \
       --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' --output text | grep -q '^igw-' \
  || die "subnet $SUBNET_ID has no internet gateway route; nodes need public IPs + internet to install"
for ip in "$VIP" "${NODE_IP_ARR[@]}"; do
  in_cidr "$ip" "$SUBNET_CIDR" || die "$ip is outside subnet $SUBNET_ID ($SUBNET_CIDR)"
  used=$(aws ec2 describe-network-interfaces --filters "Name=addresses.private-ip-address,Values=$ip" "Name=vpc-id,Values=$VPC_ID" \
    --query 'length(NetworkInterfaces)' --output text)
  [ "$used" = 0 ] || [ -n "${NODE1_ID:-}" ] || die "$ip is already in use"
done
ok "$SUBNET_ID ($SUBNET_CIDR) in $VPC_ID; VIP $VIP and nodes ${NODE_IP_ARR[*]} are free"

if [ -z "${ADMIN_CIDR:-}" ]; then
  ADMIN_CIDR="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
fi
ok "admin access from $ADMIN_CIDR"

log "Key pair $KEY_NAME"
AWS_PUB=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" --include-public-key \
  --query 'KeyPairs[0].PublicKey' --output text 2>/dev/null) || die "key pair $KEY_NAME not found in $AWS_REGION"
[ -f "$SSH_KEY_FILE" ] || die "private key $SSH_KEY_FILE not found"
LOCAL_PUB=$(ssh-keygen -y -f "$SSH_KEY_FILE" 2>/dev/null | awk '{print $2}') || die "cannot read $SSH_KEY_FILE"
[ "$LOCAL_PUB" = "$(awk '{print $2}' <<<"$AWS_PUB")" ] || die "$SSH_KEY_FILE does not match key pair $KEY_NAME"
ok "private key matches"

log "Harvester $HARVESTER_VERSION artifacts"
BASE="https://releases.rancher.com/harvester/$HARVESTER_VERSION"
for f in "harvester-$HARVESTER_VERSION-vmlinuz-amd64" "harvester-$HARVESTER_VERSION-initrd-amd64" \
         "harvester-$HARVESTER_VERSION-rootfs-amd64.squashfs" "harvester-$HARVESTER_VERSION-amd64.iso"; do
  [ "$(curl -sI -o /dev/null -w '%{http_code}' "$BASE/$f")" = 200 ] || die "missing $BASE/$f"
done
ok "kernel, initrd, rootfs and ISO are published"

log "Quotas and account settings"
NEED=$(( VCPU * 3 + 2 ))
QUOTA=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text 2>/dev/null || echo unknown)
USED=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].CpuOptions' --output json 2>/dev/null \
  | jq '[.[] | .CoreCount * .ThreadsPerCore] | add // 0' 2>/dev/null || echo 0)
if [ "$QUOTA" != unknown ] && (( ${QUOTA%.*} - ${USED%.*} < NEED )); then
  die "on-demand standard vCPU quota $QUOTA, $USED in use; need $NEED more"
fi
ok "vCPU quota $QUOTA (in use: $USED, need: $NEED)"
ACCT=$(aws sts get-caller-identity --query Account --output text)
BPP=$(aws s3control get-public-access-block --account-id "$ACCT" \
  --query 'PublicAccessBlockConfiguration.BlockPublicPolicy' --output text 2>/dev/null || echo False)
[ "$BPP" != True ] || die "account-level S3 BlockPublicPolicy is on; the install-config bucket needs an IP-restricted bucket policy"
ok "S3 account settings allow an IP-restricted bucket policy"

PRICE=$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 --filters \
  "Type=TERM_MATCH,Field=instanceType,Value=$INSTANCE_TYPE" "Type=TERM_MATCH,Field=regionCode,Value=$AWS_REGION" \
  "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
  "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
  --query 'PriceList[0]' --output text 2>/dev/null | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD' 2>/dev/null || true)
[ -n "$PRICE" ] && ok "on-demand price: \$$PRICE/hr per node, ~\$$(awk -v p="$PRICE" 'BEGIN{printf "%.2f", p*3}')/hr for 3 (plus EBS)"

if [ "$RANCHER_IMPORT" = true ]; then
  log "Rancher"
  RV=$(rkubectl get settings.management.cattle.io server-version -o jsonpath='{.value}' 2>/dev/null) \
    || die "cannot read Rancher settings with kubectl${RANCHER_KUBECONTEXT:+ (context $RANCHER_KUBECONTEXT)}; fix RANCHER_KUBECONTEXT or set RANCHER_IMPORT=false"
  TLS=$(rkubectl get settings.management.cattle.io agent-tls-mode -o jsonpath='{.value}' 2>/dev/null)
  CAC=$(rkubectl get settings.management.cattle.io cacerts -o jsonpath='{.value}' 2>/dev/null)
  ok "Rancher $RV (check the SUSE matrix: Rancher 2.14 -> Harvester v1.8.x, 2.15 -> v1.9.x; configured: $HARVESTER_VERSION)"
  if [ "${TLS:-strict}" != system-store ] && [ -z "$CAC" ]; then
    warn "Rancher agent-tls-mode is '${TLS:-strict (default)}' and cacerts is empty (public CA). The import will fail until"
    warn "agent-tls-mode is set to system-store. 05-rancher-import.sh --fix-agent-tls does this (global Rancher setting; ask first)."
  fi
fi

state_set SUBNET_ID "$SUBNET_ID"
state_set VPC_ID "$VPC_ID"
state_set SUBNET_CIDR "$SUBNET_CIDR"
state_set ADMIN_CIDR "$ADMIN_CIDR"
ok "preflight passed; state in $STATE_DIR"

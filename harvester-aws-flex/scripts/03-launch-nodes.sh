#!/usr/bin/env bash
# Launches the 3 nodes with nested virtualization, renders each node's
# Harvester install config (needs the NIC MAC and root volume ID, which only
# exist after launch), uploads it, and opens the bucket to the node IPs.
# Node 1 creates the cluster; 2 and 3 join through the VIP and retry until
# node 1 is up, so all three launch together.
#   usage: 03-launch-nodes.sh [node-number ...]   (default: 1 2 3)
source "$(dirname "$0")/lib.sh"
need aws jq
load_config
load_secrets
[ -n "${SG_ID:-}" ] && [ -n "${BUCKET:-}" ] && [ -n "${AMI_ID:-}" ] || die "run 01-create-infra.sh and 02-build-ipxe-ami.sh first"

PUBKEY=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" --include-public-key --query 'KeyPairs[0].PublicKey' --output text)
S3_HOST="$BUCKET.s3.$AWS_REGION.amazonaws.com"

render_config() { # <n> <mac> <volume-id>
  local n=$1 mac=$2 vol=$3 mode=join srv="server_url: https://$VIP:443" t
  [ "$n" = 1 ] && { mode=create; srv=""; }
  t=$(<"$SKILL_DIR/templates/harvester-config.yaml.tmpl")
  t=${t//@@SERVER_URL_LINE@@/$srv}; t=${t//@@TOKEN@@/$HARVESTER_TOKEN}; t=${t//@@NODE@@/$(node_name "$n")}
  t=${t//@@PASSWORD@@/$HARVESTER_PASSWORD}; t=${t//@@PUBKEY@@/$PUBKEY}; t=${t//@@MODE@@/$mode}
  t=${t//@@MAC@@/$mac}; t=${t//@@VOLID@@/${vol/-/}}; t=${t//@@HV@@/$HARVESTER_VERSION}; t=${t//@@VIP@@/$VIP}
  ( umask 077; grep -v '^$' <<<"$t" > "$STATE_DIR/configs/$(node_name "$n").yaml" )
  aws s3 cp --quiet "$STATE_DIR/configs/$(node_name "$n").yaml" "s3://$BUCKET/$(node_name "$n").yaml"
}

allow_node_ips() {
  local ips
  ips=$(aws ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$TAG_VAL" Name=instance-state-name,Values=pending,running \
    --query 'Reservations[].Instances[].PublicIpAddress' --output json | jq -c '[.[] | select(.) | . + "/32"]')
  [ "$ips" != "[]" ] || return 0
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(jq -cn --arg b "$BUCKET" --argjson ips "$ips" \
    '{Version:"2012-10-17",Statement:[{Sid:"NodesRead",Effect:"Allow",Principal:"*",Action:"s3:GetObject",
      Resource:("arn:aws:s3:::"+$b+"/*"),Condition:{IpAddress:{"aws:SourceIp":$ips}}}]}')"
  ok "install configs readable only from $ips"
}

launch() { # <n>
  local n=$1 name ip ips id mac eni vol
  name=$(node_name "$n"); ip=$(node_ip "$n")
  if [ -n "$(node_id "$n")" ]; then warn "$name already launched ($(node_id "$n")); skipping"; return; fi
  ips="[{\"Primary\":true,\"PrivateIpAddress\":\"$ip\"}"
  [ "$n" = 1 ] && ips="$ips,{\"Primary\":false,\"PrivateIpAddress\":\"$VIP\"}"
  ips="$ips]"
  sed -e "s|__HV__|$HARVESTER_VERSION|g" -e "s|__NODE__|$name|g" -e "s|__CONFIG_URL__|https://$S3_HOST/$name.yaml|g" \
    "$SKILL_DIR/templates/ipxe-userdata.tmpl" > "$STATE_DIR/configs/$name.ipxe"
  log "launching $name ($INSTANCE_TYPE, $ip$([ "$n" = 1 ] && echo " + VIP $VIP"))"
  id=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
    --cpu-options "NestedVirtualization=enabled" \
    --metadata-options "HttpEndpoint=enabled,HttpTokens=optional" \
    --placement "AvailabilityZone=$AZ" \
    --network-interfaces "[{\"DeviceIndex\":0,\"SubnetId\":\"$SUBNET_ID\",\"Groups\":[\"$SG_ID\"],\"AssociatePublicIpAddress\":true,\"PrivateIpAddresses\":$ips}]" \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$ROOT_VOLUME_GB,VolumeType=gp3,Iops=$ROOT_VOLUME_IOPS,Throughput=$ROOT_VOLUME_THROUGHPUT,DeleteOnTermination=true}" \
    --user-data "file://$STATE_DIR/configs/$name.ipxe" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=$TAG_KEY,Value=$TAG_VAL}]" \
                         "ResourceType=volume,Tags=[{Key=Name,Value=$name},{Key=$TAG_KEY,Value=$TAG_VAL}]" \
    --query 'Instances[0].InstanceId' --output text)
  state_set "NODE${n}_ID" "$id"
  for _ in $(seq 1 30); do
    read -r mac eni vol <<<"$(aws ec2 describe-instances --instance-ids "$id" --query \
      'Reservations[0].Instances[0].[NetworkInterfaces[0].MacAddress,NetworkInterfaces[0].NetworkInterfaceId,BlockDeviceMappings[0].Ebs.VolumeId]' --output text)"
    [[ "$vol" == vol-* ]] && break; sleep 2
  done
  [[ "$vol" == vol-* ]] || die "$name: root volume never appeared"
  aws ec2 modify-network-interface-attribute --network-interface-id "$eni" --no-source-dest-check
  state_set "NODE${n}_ENI" "$eni"
  render_config "$n" "$mac" "$vol"
  ok "$name $id eni=$eni mac=$mac vol=$vol"
}

NODES=("$@"); [ ${#NODES[@]} -gt 0 ] || NODES=(1 2 3)
for n in "${NODES[@]}"; do launch "$n"; done
for n in "${NODES[@]}"; do
  wait_until "public IP for $(node_name "$n")" 120 3 bash -c "[ \"\$(aws ec2 describe-instances --instance-ids $(node_id "$n") --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)\" != None ]"
  state_set "NODE${n}_PUBLIC_IP" "$(node_public_ip "$n")"
done
allow_node_ips
for n in 1 2 3; do v="NODE${n}_PUBLIC_IP"; [ -n "${!v:-}" ] && log "$(node_name "$n"): ${!v}"; done
ok "nodes are booting iPXE -> Harvester installer. Next: 04-postinstall.sh (takes ~15-30 min)"

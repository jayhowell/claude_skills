#!/usr/bin/env bash
# Ensures a UEFI iPXE AMI exists. The public iPXE AMIs boot legacy BIOS only
# (Harvester >= v1.8 needs UEFI) and can't be copied/re-registered, so we build
# our own: a throwaway AL2023 instance writes an ESP (iPXE + autoexec.ipxe that
# chains EC2 user-data) to a 1 GiB volume, which becomes a boot-mode=uefi AMI.
# One AMI can be reused by every cluster in the account/region (IPXE_AMI_ID).
source "$(dirname "$0")/lib.sh"
need aws
load_config

check_ami() {
  local mode state
  read -r state mode <<<"$(aws ec2 describe-images --image-ids "$1" --query 'Images[0].[State,BootMode]' --output text 2>/dev/null)" || return 1
  [ "$state" = available ] && [ "$mode" = uefi ]
}

if [ -n "${IPXE_AMI_ID:-}" ]; then
  check_ami "$IPXE_AMI_ID" || die "IPXE_AMI_ID $IPXE_AMI_ID is not an available boot-mode=uefi AMI in $AWS_REGION"
  state_set AMI_ID "$IPXE_AMI_ID"; ok "using existing UEFI iPXE AMI $AMI_ID"; exit 0
fi
if [ -n "${AMI_ID:-}" ] && check_ami "$AMI_ID"; then ok "UEFI iPXE AMI $AMI_ID already built"; exit 0; fi
[ -n "${SG_ID:-}" ] || die "run 01-create-infra.sh first"

AL=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
log "creating 1 GiB ESP volume"
VOL=$(aws ec2 create-volume --availability-zone "$AZ" --size 1 --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$CLUSTER_NAME-ipxe-esp},{Key=$TAG_KEY,Value=$TAG_VAL}]" \
  --query VolumeId --output text)
aws ec2 wait volume-available --volume-ids "$VOL"

UD="$STATE_DIR/configs/esp-builder-userdata.sh"
sed -e "s|__VOLUME_ID__|$VOL|g" -e "s|__IPXE_EFI_URL__|$IPXE_EFI_URL|g" "$SKILL_DIR/templates/esp-builder-userdata.sh.tmpl" > "$UD"
log "launching throwaway builder (t3.micro, $AL)"
HID=$(aws ec2 run-instances --image-id "$AL" --instance-type t3.micro \
  --instance-initiated-shutdown-behavior stop --user-data "file://$UD" \
  --network-interfaces "[{\"DeviceIndex\":0,\"SubnetId\":\"$SUBNET_ID\",\"Groups\":[\"$SG_ID\"],\"AssociatePublicIpAddress\":true}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$CLUSTER_NAME-ami-builder},{Key=$TAG_KEY,Value=$TAG_VAL}]" \
  --query 'Instances[0].InstanceId' --output text)
cleanup() { aws ec2 terminate-instances --instance-ids "$HID" >/dev/null 2>&1 || true
            aws ec2 wait instance-terminated --instance-ids "$HID" 2>/dev/null || true
            aws ec2 delete-volume --volume-id "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT
aws ec2 wait instance-running --instance-ids "$HID"
aws ec2 attach-volume --volume-id "$VOL" --instance-id "$HID" --device /dev/sdf >/dev/null

log "waiting for the builder to write the ESP and power off (~2-4 min)"
wait_until "builder $HID to stop" 900 15 \
  bash -c "[ \"\$(aws ec2 describe-instances --instance-ids $HID --query 'Reservations[0].Instances[0].State.Name' --output text)\" = stopped ]"
OUT=$(console_tail "$HID" 200)
grep -q 'HAF-ESP-BUILD-OK' <<<"$OUT" || { echo "$OUT" | tail -40 >&2; die "ESP build did not report success (console above)"; }
ok "$(grep -o 'HAF-ESP-BUILD-OK.*' <<<"$OUT" | head -1)"

aws ec2 detach-volume --volume-id "$VOL" >/dev/null
aws ec2 wait volume-available --volume-ids "$VOL"
SNAP=$(aws ec2 create-snapshot --volume-id "$VOL" --description "UEFI iPXE ESP ($IPXE_EFI_URL + autoexec user-data chain)" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=ipxe-uefi-esp},{Key=$TAG_KEY,Value=$TAG_VAL}]" \
  --query SnapshotId --output text)
aws ec2 wait snapshot-completed --snapshot-ids "$SNAP"
AMI_ID=$(aws ec2 register-image --name "ipxe-uefi-userdata-$CLUSTER_NAME-$(date +%Y%m%d%H%M)" \
  --description "iPXE UEFI; chains EC2 user-data (needs IMDS HttpTokens=optional)" \
  --architecture x86_64 --boot-mode uefi --ena-support --root-device-name /dev/xvda --virtualization-type hvm \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$SNAP,VolumeType=gp3,DeleteOnTermination=true}" \
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=ipxe-uefi-userdata},{Key=$TAG_KEY,Value=$TAG_VAL}]" \
  --query ImageId --output text)
aws ec2 wait image-available --image-ids "$AMI_ID"
state_set AMI_ID "$AMI_ID"
state_set AMI_SNAPSHOT_ID "$SNAP"
ok "UEFI iPXE AMI $AMI_ID (snapshot $SNAP). Reuse it for other clusters with IPXE_AMI_ID=$AMI_ID"

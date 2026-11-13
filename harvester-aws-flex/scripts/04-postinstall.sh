#!/usr/bin/env bash
# Waits for the install, then makes the cluster safe to use on EC2:
#  - fetches a kubeconfig (via node 1's public IP)
#  - pins each node's flannel VXLAN address to its own private IP as soon as
#    the node registers (otherwise a node that briefly holds the VIP at boot can
#    register the VIP as its tunnel endpoint and its pod network goes dark)
#  - waits for 3 Ready nodes, checks MTU/VIP/Longhorn
#  - adds the longhorn-rwx StorageClass (NFS-backed RWX for shared filesystems)
#  - optionally switches the nodes to IMDSv2-only
source "$(dirname "$0")/lib.sh"
need aws kubectl curl ssh
load_config
[ -n "${NODE1_ID:-}" ] || die "no nodes in state; run 03-launch-nodes.sh"

for n in 1 2 3; do state_set "NODE${n}_PUBLIC_IP" "$(node_public_ip "$n")"; done
P1=$NODE1_PUBLIC_IP

log "waiting for the Harvester UI on node 1 (https://$P1), usually 15-25 min after launch"
start=$(date +%s)
until [ "$(curl -k -s -m 6 -o /dev/null -w '%{http_code}' "https://$P1/dashboard/")" = 200 ]; do
  (( $(date +%s) - start > 3600 )) && { console_tail "$NODE1_ID" 30 >&2; die "UI not up after 60 min (node 1 console above; see SKILL.md troubleshooting)"; }
  if (( ($(date +%s) - start) % 300 < 30 )); then log "  still installing... console: $(console_tail "$NODE1_ID" 1 | cut -c1-120)"; fi
  sleep 30
done
ok "UI is up"

log "fetching kubeconfig"
( umask 077; node_ssh "$P1" 'sudo cat /etc/rancher/rke2/rke2.yaml' > "$KUBECONFIG_FILE" )
sed -i.bak "s#https://127.0.0.1:6443#https://$P1:6443#" "$KUBECONFIG_FILE" && rm -f "$KUBECONFIG_FILE.bak"
# The RKE2 serving cert doesn't include the public IP.
kubectl --kubeconfig "$KUBECONFIG_FILE" config set-cluster default --insecure-skip-tls-verify=true >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" config unset clusters.default.certificate-authority-data >/dev/null
ok "kubeconfig: $KUBECONFIG_FILE"

log "pinning flannel public IPs as nodes register; waiting for 3 Ready nodes (joins take ~5-15 min)"
pinned=" "
start=$(date +%s)
while :; do
  for n in 1 2 3; do
    [[ "$pinned" == *" $n "* ]] && continue
    if hkubectl get node "$(node_name "$n")" >/dev/null 2>&1; then
      hkubectl annotate node "$(node_name "$n")" "flannel.alpha.coreos.com/public-ip-overwrite=$(node_ip "$n")" --overwrite >/dev/null
      pinned="$pinned$n "; ok "pinned $(node_name "$n") flannel IP to $(node_ip "$n")"
    fi
  done
  ready=$(hkubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  [ "$ready" = 3 ] && [ "$(tr -cd 0-9 <<<"$pinned" | wc -c | tr -d ' ')" = 3 ] && break
  (( $(date +%s) - start > 2700 )) && die "only $ready/3 nodes Ready after 45 min (see SKILL.md troubleshooting: joins)"
  sleep 15
done
ok "3 nodes Ready"

log "verifying flannel endpoints"
for n in 1 2 3; do
  got=$(hkubectl get node "$(node_name "$n")" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}')
  if [ "$got" != "$(node_ip "$n")" ]; then
    warn "$(node_name "$n") flannel public-ip is '$got'; restarting its canal pod"
    hkubectl -n kube-system delete pod -l k8s-app=canal --field-selector "spec.nodeName=$(node_name "$n")" >/dev/null
  fi
done
hkubectl -n kube-system rollout status ds/rke2-canal --timeout=300s >/dev/null
ok "flannel endpoints: $(for n in 1 2 3; do hkubectl get node "$(node_name "$n")" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip} '; done)"

log "checking MTU on every node"
for n in 1 2 3; do
  p=$(node_public_ip "$n")
  m=$(node_ssh "$p" 'cat /sys/class/net/mgmt-br/mtu') || die "cannot ssh to $(node_name "$n")"
  [ "$m" = 1500 ] || die "$(node_name "$n") mgmt-br MTU is $m (expected 1500); see SKILL.md troubleshooting: MTU"
done
ok "mgmt-br MTU 1500 on all nodes"

log "waiting for Longhorn on all nodes"
for i in $(seq 1 60); do
  [ "$(hkubectl -n longhorn-system get nodes.longhorn.io -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Schedulable")].status}{"\n"}{end}' 2>/dev/null | grep -c True)" = 3 ] && break
  [ "$i" = 60 ] && die "Longhorn is not schedulable on all 3 nodes after 15 min"
  sleep 15
done
ok "Longhorn ready and schedulable on 3 nodes"

log "adding StorageClass longhorn-rwx"
hkubectl apply -f "$SKILL_DIR/templates/longhorn-rwx-storageclass.yaml" >/dev/null
ok "longhorn-rwx (NFS share-manager RWX). VM disks stay on harvester-longhorn (block RWX for live migration)"

LEADER=$(hkubectl -n harvester-system get lease plndr-svcs-lock -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
if [ "$LEADER" = "$(node_name 1)" ]; then ok "kube-vip leader is node 1 (matches where AWS routes the VIP)"
else warn "kube-vip leader is '$LEADER', but AWS routes the VIP to node 1. Run vip-follow.sh"; fi

if [ "$IMDS_REQUIRE_TOKENS_AFTER_INSTALL" = true ]; then
  for n in 1 2 3; do
    aws ec2 modify-instance-metadata-options --instance-id "$(node_id "$n")" --http-tokens required --http-endpoint enabled >/dev/null
  done
  ok "IMDSv2 now required on all nodes (set HttpTokens=optional again before any re-install via iPXE)"
fi

load_secrets
cat >&2 <<EOF

  Harvester $HARVESTER_VERSION cluster $CLUSTER_NAME is ready.
    UI:          https://$P1   (first visit: set the admin password)
    kubeconfig:  $KUBECONFIG_FILE
    node SSH:    ssh -i $SSH_KEY_FILE rancher@<node public IP>   (password in secrets.env)
    nodes:       $(for n in 1 2 3; do printf '%s=%s ' "$(node_name "$n")" "$(node_public_ip "$n")"; done)
  Next: 05-rancher-import.sh (optional), 06-verify-rwx.sh, 07-cleanup-install-configs.sh
EOF

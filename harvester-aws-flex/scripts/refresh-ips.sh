#!/usr/bin/env bash
# Run after starting stopped nodes: public IPs change on every stop/start.
# Updates state + kubeconfig, then reports node, VIP and flannel health.
source "$(dirname "$0")/lib.sh"
need aws kubectl
load_config
for n in 1 2 3; do
  st=$(aws ec2 describe-instances --instance-ids "$(node_id "$n")" --query 'Reservations[0].Instances[0].State.Name' --output text)
  ip=$(node_public_ip "$n")
  state_set "NODE${n}_PUBLIC_IP" "$ip"
  log "$(node_name "$n"): $st $ip"
done
[ "$NODE1_PUBLIC_IP" != None ] || die "node 1 has no public IP (is it running?)"
if [ -f "$KUBECONFIG_FILE" ]; then
  sed -i.bak -E "s#server: https://[^:]+:6443#server: https://$NODE1_PUBLIC_IP:6443#" "$KUBECONFIG_FILE" && rm -f "$KUBECONFIG_FILE.bak"
  ok "kubeconfig now points at $NODE1_PUBLIC_IP"
  hkubectl get nodes 2>/dev/null || warn "API not reachable yet (Harvester takes ~5-10 min after boot)"
  for n in 1 2 3; do
    got=$(hkubectl get node "$(node_name "$n")" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}' 2>/dev/null || true)
    [ -z "$got" ] || [ "$got" = "$(node_ip "$n")" ] || warn "$(node_name "$n") flannel public-ip is $got (expected $(node_ip "$n")); see SKILL.md: flannel"
  done
  LEADER=$(hkubectl -n harvester-system get lease plndr-svcs-lock -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
  [ -z "$LEADER" ] || [ "$LEADER" = "$(node_name 1)" ] || warn "kube-vip leader is $LEADER; run vip-follow.sh so the VIP works"
fi
ok "UI: https://$NODE1_PUBLIC_IP"

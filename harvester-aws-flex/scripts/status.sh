#!/usr/bin/env bash
# One-shot health/debug snapshot. Safe to run any time (read-only).
#   usage: status.sh [--console N]   show the last N serial-console lines per node
source "$(dirname "$0")/lib.sh"
need aws
load_config
CON=0; [ "${1:-}" = --console ] && CON=${2:-20}
for n in 1 2 3; do
  id=$(node_id "$n"); [ -n "$id" ] || { warn "$(node_name "$n") not launched"; continue; }
  read -r st ip <<<"$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text)"
  ui=$(curl -k -s -m 5 -o /dev/null -w '%{http_code}' "https://$ip/dashboard/" 2>/dev/null || echo -)
  printf '%-24s %-20s %-8s %-16s ui=%s\n' "$(node_name "$n")" "$id" "$st" "$ip" "$ui"
  if [ "$CON" -gt 0 ]; then console_tail "$id" "$CON" | sed 's/^/    | /'; fi
done
if [ -f "$KUBECONFIG_FILE" ] && hkubectl get nodes >/dev/null 2>&1; then
  echo; hkubectl get nodes -o wide
  echo; hkubectl -n longhorn-system get nodes.longhorn.io 2>/dev/null || true
  echo; echo "flannel endpoints:"; for n in 1 2 3; do printf '  %s -> %s\n' "$(node_name "$n")" \
    "$(hkubectl get node "$(node_name "$n")" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}' 2>/dev/null)"; done
  echo "kube-vip leader: $(hkubectl -n harvester-system get lease plndr-svcs-lock -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)"
  echo; echo "unhealthy pods:"; hkubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | head -20
else
  echo; warn "Kubernetes API not reachable via $KUBECONFIG_FILE (still installing, IPs changed -> refresh-ips.sh, or no kubeconfig yet)"
  echo "  Live installer:  ssh rancher@<ip> (password: rancher), then: sudo tail -f /var/log/console.log"
fi

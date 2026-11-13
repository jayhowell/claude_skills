#!/usr/bin/env bash
# Proves filesystem RWX on Longhorn/EBS: pods on nodes 2 and 3 write to the
# same longhorn-rwx volume and each must see both writes. Cleans up after.
source "$(dirname "$0")/lib.sh"
need kubectl
load_config
[ -f "$KUBECONFIG_FILE" ] || die "no kubeconfig; run 04-postinstall.sh first"

A=$(node_name 2); B=$(node_name 3)
cleanup() { hkubectl delete pod haf-rwx-writer-a haf-rwx-writer-b --wait=false >/dev/null 2>&1 || true
            hkubectl delete pvc haf-rwx-test --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
sed -e "s/__NODE_A__/$A/g" -e "s/__NODE_B__/$B/g" "$SKILL_DIR/templates/rwx-test.yaml" | hkubectl apply -f - >/dev/null
log "waiting for writer pods on $A and $B"
hkubectl wait --for=condition=Ready pod/haf-rwx-writer-a pod/haf-rwx-writer-b --timeout=300s >/dev/null \
  || { hkubectl describe pod haf-rwx-writer-a | tail -8 >&2; die "RWX pods did not start"; }
sleep 3
for p in haf-rwx-writer-a haf-rwx-writer-b; do
  got=$(hkubectl exec "$p" -- cat /data/shared.txt | sort | tr '\n' ' ')
  [[ "$got" == *"from-$A"* && "$got" == *"from-$B"* ]] || die "$p sees '$got'"
  ok "$p sees: $got"
done
SM=$(hkubectl -n longhorn-system get pods -l longhorn.io/component=share-manager -o jsonpath='{range .items[*]}{.metadata.name}@{.spec.nodeName} {end}')
ok "RWX works (share-manager: $SM)"

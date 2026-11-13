#!/usr/bin/env bash
# Imports the cluster into Rancher (Virtualization Management) using kubectl
# against the Rancher local cluster; no Rancher username/password needed.
#   usage: 05-rancher-import.sh [--fix-agent-tls]
#   --fix-agent-tls  set Rancher's GLOBAL agent-tls-mode to system-store when
#                    Rancher uses a publicly trusted cert (cacerts empty) and
#                    the mode is strict. Affects every downstream agent; get
#                    the Rancher owner's OK first.
source "$(dirname "$0")/lib.sh"
need kubectl curl
load_config
FIX_TLS=false; [ "${1:-}" = --fix-agent-tls ] && FIX_TLS=true
[ -f "$KUBECONFIG_FILE" ] || die "no kubeconfig; run 04-postinstall.sh first"

RV=$(rkubectl get settings.management.cattle.io server-version -o jsonpath='{.value}') || die "cannot reach Rancher with kubectl"
SERVER_URL=$(rkubectl get settings.management.cattle.io server-url -o jsonpath='{.value}')
ok "Rancher $RV at $SERVER_URL"

TLS=$(rkubectl get settings.management.cattle.io agent-tls-mode -o jsonpath='{.value}')
CAC=$(rkubectl get settings.management.cattle.io cacerts -o jsonpath='{.value}')
if [ "${TLS:-strict}" != system-store ] && [ -z "$CAC" ]; then
  if [ "$FIX_TLS" = true ]; then
    rkubectl patch settings.management.cattle.io agent-tls-mode --type merge -p '{"value":"system-store"}' >/dev/null
    ok "Rancher agent-tls-mode set to system-store"
  else
    die "Rancher agent-tls-mode is strict and Rancher has no CA bundle (public cert); the cluster agent would crash with
     'Strict CA verification is enabled but encountered error finding root CA'. Re-run with --fix-agent-tls
     (global Rancher setting; confirm with the Rancher owner) or provide Rancher's CA in the cacerts setting."
  fi
fi

log "checking the nodes can reach Rancher"
node_ssh "$(node_public_ip 1)" "curl -fsS -m 10 -o /dev/null $SERVER_URL/ping" || die "node 1 cannot reach $SERVER_URL/ping"

log "creating Rancher cluster $CLUSTER_NAME"
rkubectl apply -f - >/dev/null <<EOF
apiVersion: provisioning.cattle.io/v1
kind: Cluster
metadata:
  name: $CLUSTER_NAME
  namespace: fleet-default
  labels:
    provider.cattle.io: harvester
  annotations:
    field.cattle.io/description: "Harvester $HARVESTER_VERSION on 3 x $INSTANCE_TYPE (EC2 nested virtualization, $AWS_REGION), Longhorn on EBS"
spec:
  agentEnvVars: []
EOF
CID=""
for _ in $(seq 1 40); do
  CID=$(rkubectl -n fleet-default get clusters.provisioning.cattle.io "$CLUSTER_NAME" -o jsonpath='{.status.clusterName}' 2>/dev/null || true)
  [ -n "$CID" ] && break; sleep 3
done
[ -n "$CID" ] || die "Rancher did not assign a cluster id"
state_set RANCHER_CLUSTER_ID "$CID"
URL=""
for _ in $(seq 1 40); do
  URL=$(rkubectl -n "$CID" get clusterregistrationtokens.management.cattle.io -o jsonpath='{.items[0].status.manifestUrl}' 2>/dev/null || true)
  [ -n "$URL" ] && break; sleep 3
done
[ -n "$URL" ] || die "no registration URL for $CID"

log "pointing Harvester at Rancher (cluster-registration-url)"
hkubectl patch settings.harvesterhci.io cluster-registration-url --type merge -p "{\"value\":\"$URL\"}" >/dev/null

log "waiting for the cattle-cluster-agent"
sleep 60
if hkubectl -n cattle-system logs deploy/cattle-cluster-agent --tail=30 2>/dev/null | grep -q 'Strict CA verification'; then
  warn "agent was deployed with strict TLS; re-applying the current import manifest"
  curl -fsS "$URL" | hkubectl apply -f - >/dev/null
fi
log "waiting for Rancher to report $CLUSTER_NAME Ready (up to 15 min)"
for i in $(seq 1 90); do
  [ "$(rkubectl get clusters.management.cattle.io "$CID" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
  [ "$i" = 90 ] && die "Rancher never reported $CID Ready: $(rkubectl get clusters.management.cattle.io "$CID" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  sleep 10
done
ok "$CLUSTER_NAME ($CID) is Ready in Rancher: $SERVER_URL/dashboard/harvester/c/$CID"
warn "if the Rancher UI shows %harvester...% labels or 'error loading the code for this Extension', see SKILL.md troubleshooting"

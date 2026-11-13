#!/usr/bin/env bash
# Shared helpers for the harvester-aws-flex scripts. Source this; don't run it.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAF_CONFIG="${HAF_CONFIG:-$PWD/cluster.env}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%T)" "$*" >&2; }
ok()   { printf '\033[1;32m[%s] OK:\033[0m %s\n' "$(date +%T)" "$*" >&2; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%T)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%T)" "$*" >&2; exit 1; }

need() { local t; for t in "$@"; do command -v "$t" >/dev/null || die "missing required tool: $t"; done; }

load_config() {
  [ -f "$HAF_CONFIG" ] || die "config not found: $HAF_CONFIG (copy $SKILL_DIR/config/cluster.env.example to ./cluster.env)"
  # shellcheck disable=SC1090
  source "$HAF_CONFIG"
  local v
  for v in AWS_REGION AZ KEY_NAME SSH_KEY_FILE CLUSTER_NAME NODE_PREFIX INSTANCE_TYPE \
           HARVESTER_VERSION VIP NODE_IPS ROOT_VOLUME_GB; do
    [ -n "${!v:-}" ] || die "$v must be set in $HAF_CONFIG"
  done
  SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
  ROOT_VOLUME_IOPS="${ROOT_VOLUME_IOPS:-3000}"
  ROOT_VOLUME_THROUGHPUT="${ROOT_VOLUME_THROUGHPUT:-125}"
  IPXE_EFI_URL="${IPXE_EFI_URL:-https://boot.ipxe.org/x86_64-efi/ipxe.efi}"
  IMDS_REQUIRE_TOKENS_AFTER_INSTALL="${IMDS_REQUIRE_TOKENS_AFTER_INSTALL:-true}"
  RANCHER_IMPORT="${RANCHER_IMPORT:-false}"
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

  read -r -a NODE_IP_ARR <<<"$NODE_IPS"
  [ "${#NODE_IP_ARR[@]}" -eq 3 ] || die "NODE_IPS must list exactly 3 IPs"

  STATE_DIR="${STATE_DIR:-$(cd "$(dirname "$HAF_CONFIG")" && pwd)/state-$CLUSTER_NAME}"
  mkdir -p "$STATE_DIR/configs"
  chmod 700 "$STATE_DIR" "$STATE_DIR/configs"
  touch "$STATE_DIR/state.env"; chmod 600 "$STATE_DIR/state.env"
  # shellcheck disable=SC1091
  source "$STATE_DIR/state.env"
  KUBECONFIG_FILE="$STATE_DIR/$CLUSTER_NAME.kubeconfig"
  TAG_KEY=Project
  TAG_VAL="$CLUSTER_NAME"
}

# Persist KEY=VALUE into state.env and set it in the current shell.
state_set() {
  local k=$1 v=$2 f="$STATE_DIR/state.env"
  { grep -v "^$k=" "$f" || true; printf '%s=%q\n' "$k" "$v"; } > "$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f"
  printf -v "$k" '%s' "$v"
}
state_unset() { local f="$STATE_DIR/state.env"; { grep -v "^$1=" "$f" || true; } > "$f.tmp"; mv "$f.tmp" "$f"; unset "$1"; }

load_secrets() {
  [ -f "$STATE_DIR/secrets.env" ] || die "no secrets.env in $STATE_DIR (run 01-create-infra.sh)"
  # shellcheck disable=SC1091
  source "$STATE_DIR/secrets.env"
}

node_name() { echo "$NODE_PREFIX$1"; }
node_ip()   { echo "${NODE_IP_ARR[$(($1 - 1))]}"; }
node_id()   { local v="NODE$1_ID"; echo "${!v:-}"; }

node_public_ip() {
  aws ec2 describe-instances --instance-ids "$(node_id "$1")" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

# SSH to an installed Harvester node as rancher (key auth).
node_ssh() { local h=$1; shift; ssh -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes "${SSH_OPTS[@]}" "rancher@$h" "$@"; }

# SSH to a node still in the live installer (rancher/rancher password auth).
live_ssh() {
  local h=$1; shift
  local ap="$STATE_DIR/.askpass"
  [ -x "$ap" ] || { printf '#!/bin/sh\necho rancher\n' > "$ap"; chmod 700 "$ap"; }
  SSH_ASKPASS="$ap" SSH_ASKPASS_REQUIRE=force ssh -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
    "${SSH_OPTS[@]}" "rancher@$h" "$@" </dev/null
}

# Latest serial console output, ANSI stripped.
console_tail() {
  aws ec2 get-console-output --instance-id "$1" --latest --output text --query Output 2>/dev/null \
    | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' | grep -v '^[[:space:]]*$' | tail -"${2:-15}"
}

hkubectl() { kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=20s "$@"; }
rkubectl() { if [ -n "${RANCHER_KUBECONTEXT:-}" ]; then kubectl --context "$RANCHER_KUBECONTEXT" "$@"; else kubectl "$@"; fi; }

# wait_until <description> <timeout-seconds> <interval> <command...>
wait_until() {
  local desc=$1 timeout=$2 interval=$3; shift 3
  local start; start=$(date +%s)
  until "$@"; do
    (( $(date +%s) - start > timeout )) && die "timed out after ${timeout}s waiting for: $desc"
    sleep "$interval"
  done
}

ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
in_cidr() {
  local ip=$1 net=${2%/*} bits=${2#*/}
  local mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(ip2int "$ip") & mask) == ($(ip2int "$net") & mask) ))
}

confirm() {
  [ "${HAF_YES:-}" = 1 ] && return 0
  local ans; read -r -p "$1 [y/N] " ans; [[ "$ans" =~ ^[Yy] ]]
}

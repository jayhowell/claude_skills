#!/usr/bin/env bash
# Deletes the install-config bucket (it holds the node password and cluster
# token). Nodes boot from disk after install and never need it again.
source "$(dirname "$0")/lib.sh"
need aws
load_config
[ -n "${BUCKET:-}" ] || { ok "no install-config bucket in state"; exit 0; }
aws s3 rm "s3://$BUCKET" --recursive --quiet 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || warn "bucket $BUCKET already gone"
state_unset BUCKET
ok "deleted install-config bucket"

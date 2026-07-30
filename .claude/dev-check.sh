#!/usr/bin/env bash
# Project-specific service/tooling health checks.
# Each check prints: SERVICE_NAME | STATUS | detail
# STATUS: UP or DOWN

set -uo pipefail

PROXMOX_HOST="192.168.10.50"

check_bin() {
  local name="$1" bin="$2" hint="$3"
  if command -v "$bin" >/dev/null 2>&1; then
    echo "$name | UP | $(command -v "$bin")"
  else
    echo "$name | DOWN | $hint"
  fi
}

check_bin "terraform" "terraform" "install Terraform CLI (needed from Phase 1 onward)"
check_bin "ansible"   "ansible-playbook" "install Ansible (needed from Phase 2 onward)"
check_bin "kubectl"   "kubectl" "install kubectl (needed once the k3s cluster exists)"
check_bin "helm"      "helm" "install Helm (needed from Phase 3 onward)"

if curl -sk --max-time 3 "https://${PROXMOX_HOST}:8006" >/dev/null 2>&1; then
  echo "proxmox-host | UP | ${PROXMOX_HOST}:8006 responded"
else
  echo "proxmox-host | DOWN | no response from ${PROXMOX_HOST}:8006 (VPN/LAN connectivity?)"
fi

if [ -f "$HOME/.kube/config" ] && kubectl --request-timeout=3s get nodes >/dev/null 2>&1; then
  echo "k3s-cluster | UP | kubectl get nodes succeeded"
else
  echo "k3s-cluster | DOWN | no reachable cluster yet (expected before Phase 2 completes)"
fi

#!/usr/bin/env bash
# PX-035: codifies the manual live-cluster verification every ticket in
# this project has run by hand — nodes Ready, ArgoCD Applications
# Synced/Healthy, ingress paths returning real HTTP 200, Prometheus
# targets all up. Read-only, idempotent, never wired into CI: this is
# the one script in this repo that touches the live cluster, invoked
# deliberately by a human as part of a ticket's close-out, not
# automatically. See docs/TICKETS.md PX-035 / docs/SPEC.md.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Matches the k3s-server role's default fetch path
# (ansible/roles/k3s-server/defaults/main.yml: "{{ playbook_dir }}/../.kubeconfig")
# — only used if the caller hasn't already exported their own KUBECONFIG.
: "${KUBECONFIG:="$repo_root/.kubeconfig"}"
export KUBECONFIG

# Real dedicated LoadBalancer IP (MetalLB, PX-021) — see docs/SPEC.md §4.
# Hit by IP with an explicit Host header rather than relying on the
# operator machine's /etc/hosts entries, so this script's result
# doesn't depend on local DNS/hosts-file state.
ingress_lb_ip="192.168.10.13"
# host:path pairs. "/" isn't always the right check: Grafana redirects
# unauthenticated "/" to "/login" (302, correct behavior, not a
# failure), and Jenkins denies anonymous read on "/" (403, also
# correct — confirmed for real via its own X-Jenkins/
# X-Required-Permission response headers, not a broken ingress). Both
# use an endpoint that's genuinely 200 without auth instead, so a
# non-200 here means the path is actually broken, not just "requires
# login."
ingress_hosts=(
  "argocd.lab.test:/"
  "grafana.lab.test:/api/health"
  "jenkins.lab.test:/login"
  "status.lab.test:/"
)

prometheus_namespace="monitoring"
prometheus_service="prometheus-server"
prometheus_local_port="19090"

failures=0

pass() { printf '  OK    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

echo "== Nodes =="
not_ready="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk '$2 != "True" {print $1}')"
node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$not_ready" ] && [ "$node_count" = "3" ]; then
  pass "all 3 nodes Ready"
else
  fail "expected 3 nodes Ready, got $node_count node(s), not-Ready: ${not_ready:-<none, but count mismatch>}"
fi

echo "== ArgoCD Applications =="
not_synced_or_healthy="$(kubectl get applications.argoproj.io -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null | awk '$2 != "Synced" || $3 != "Healthy" {print $1" (sync="$2", health="$3")"}')"
app_count="$(kubectl get applications.argoproj.io -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$app_count" -gt 0 ] && [ -z "$not_synced_or_healthy" ]; then
  pass "all $app_count ArgoCD Application(s) Synced/Healthy"
else
  fail "ArgoCD Applications not all Synced/Healthy (or none found): ${not_synced_or_healthy:-none found}"
fi

echo "== Ingress paths =="
for entry in "${ingress_hosts[@]}"; do
  host="${entry%%:*}"
  path="${entry#*:}"
  status_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $host" "http://$ingress_lb_ip$path" 2>/dev/null || echo "000")"
  if [ "$status_code" = "200" ]; then
    pass "$host$path -> $status_code"
  else
    fail "$host$path -> $status_code (expected 200)"
  fi
done

echo "== Prometheus targets =="
port_forward_pid=""
# shellcheck disable=SC2317 # only invoked indirectly, via the trap below
cleanup_port_forward() {
  if [ -n "$port_forward_pid" ]; then
    kill "$port_forward_pid" >/dev/null 2>&1 || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi
}
trap cleanup_port_forward EXIT

kubectl -n "$prometheus_namespace" port-forward "svc/$prometheus_service" "$prometheus_local_port:80" >/dev/null 2>&1 &
port_forward_pid=$!

targets_json=""
for _ in $(seq 1 10); do
  targets_json="$(curl -s --max-time 3 "http://127.0.0.1:$prometheus_local_port/api/v1/targets" 2>/dev/null || true)"
  [ -n "$targets_json" ] && break
  sleep 1
done

if [ -z "$targets_json" ]; then
  fail "could not reach Prometheus's /api/v1/targets via port-forward"
else
  down_targets="$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("PARSE_ERROR")
    sys.exit(0)
active = data.get("data", {}).get("activeTargets", [])
down = [t.get("labels", {}).get("job", "unknown") for t in active if t.get("health") != "up"]
print(",".join(down))
' <<<"$targets_json")"

  if [ "$down_targets" = "PARSE_ERROR" ]; then
    fail "Prometheus /api/v1/targets returned unparseable JSON"
  elif [ -z "$down_targets" ]; then
    pass "all Prometheus targets up"
  else
    fail "Prometheus targets down: $down_targets"
  fi
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$failures check(s) failed."
  exit 1
fi

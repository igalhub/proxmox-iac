#!/usr/bin/env bash
# Lints every k8s/<component>/values.yaml against its real upstream chart.
# helm lint requires an actual chart directory (Chart.yaml + templates),
# and this repo's k8s/ only holds values files for remote charts — so
# each chart is pulled fresh before linting, not linted in place.
set -euo pipefail

declare -A CHART_REPOS=(
  [ingress-nginx]="https://kubernetes.github.io/ingress-nginx"
  [sealed-secrets]="https://bitnami.github.io/sealed-secrets"
  [bitnami]="https://charts.bitnami.com/bitnami"
  [postgres-operator-charts]="https://opensource.zalando.com/postgres-operator/charts/postgres-operator"
  [prometheus-community]="https://prometheus-community.github.io/helm-charts"
  [grafana]="https://grafana.github.io/helm-charts"
  [jenkins]="https://charts.jenkins.io"
)

declare -A COMPONENT_CHARTS=(
  [nginx-ingress]="ingress-nginx/ingress-nginx"
  [sealed-secrets]="sealed-secrets/sealed-secrets"
  [redis]="bitnami/redis"
  [postgres-operator]="postgres-operator-charts/postgres-operator"
  [kube-state-metrics]="prometheus-community/kube-state-metrics"
  [node-exporter]="prometheus-community/prometheus-node-exporter"
  [prometheus]="prometheus-community/prometheus"
  [grafana]="grafana/grafana"
  [jenkins]="jenkins/jenkins"
)

for name in "${!CHART_REPOS[@]}"; do
  helm repo add "$name" "${CHART_REPOS[$name]}"
done
helm repo update

lint_dir=$(mktemp -d)
trap 'rm -rf "$lint_dir"' EXIT

status=0
linted_count=0
expected_count=${#COMPONENT_CHARTS[@]}

for component in "${!COMPONENT_CHARTS[@]}"; do
  values_file="k8s/${component}/values.yaml"
  if [ ! -f "$values_file" ]; then
    echo "ERROR: expected values file not found: ${values_file}" >&2
    status=1
    continue
  fi

  chart_ref="${COMPONENT_CHARTS[$component]}"
  chart_name="${chart_ref#*/}"

  echo "--- helm lint: ${component} (${chart_ref}) ---"
  helm pull "$chart_ref" --untar -d "$lint_dir/$component" >/dev/null
  if ! helm lint "$lint_dir/$component/$chart_name" -f "$values_file"; then
    status=1
  fi
  linted_count=$((linted_count + 1))
done

if [ "$linted_count" -ne "$expected_count" ]; then
  echo "ERROR: linted ${linted_count} component(s), expected ${expected_count} — a component was silently skipped" >&2
  status=1
fi

exit "$status"

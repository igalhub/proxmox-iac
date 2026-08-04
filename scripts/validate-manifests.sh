#!/usr/bin/env bash
# Schema-validates every manifest under k8s/ via kubeconform — both
# Helm-templated output (rendered fresh from each chart + this repo's
# values.yaml, same pattern as helm-lint-values.sh) and plain manifests
# (SealedSecrets, the postgresql CR, MetalLB/Longhorn config, ArgoCD
# Applications, the landing page's own manifests). Fully offline: no
# live cluster required, only network access to pull charts/schemas.
set -euo pipefail

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "kubeconform not installed locally — install it before running this script." >&2
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
# shellcheck source=./lib/helm-charts.sh
# shellcheck disable=SC1091 # path is resolved at runtime, not statically followable
source "$script_dir/lib/helm-charts.sh"

# Local schemas checked first (see scripts/crd-schemas/README.md for
# which two are patched and why), then the community CRD catalog, then
# kubeconform's own default (built-in Kubernetes types) schema set.
# -ignore-missing-schemas: CustomResourceDefinition objects themselves
# (charts bundling their own CRDs) have no schema in any catalog — a
# known kubeconform/upstream gap, not a real validation failure.
SCHEMA_LOCATIONS=(
  -strict
  -ignore-missing-schemas
  -schema-location "$repo_root/scripts/crd-schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

for name in "${!CHART_REPOS[@]}"; do
  helm repo add "$name" "${CHART_REPOS[$name]}" >/dev/null
done
helm repo update >/dev/null

status=0

echo "=== Helm-templated manifests ==="
for component in "${!COMPONENT_CHARTS[@]}"; do
  values_file="$repo_root/k8s/${component}/values.yaml"
  if [ ! -f "$values_file" ]; then
    echo "ERROR: expected values file not found: ${values_file}" >&2
    status=1
    continue
  fi

  chart_ref="${COMPONENT_CHARTS[$component]}"
  echo "--- ${component} (${chart_ref}) ---"
  if ! helm template "$component" "$chart_ref" -f "$values_file" \
      | kubeconform -summary "${SCHEMA_LOCATIONS[@]}" -; then
    status=1
  fi
done

echo
echo "=== Plain manifests ==="
mapfile -t plain_manifests < <(find "$repo_root/k8s" -name '*.yaml' ! -name 'values.yaml' | sort)
if [ "${#plain_manifests[@]}" -eq 0 ]; then
  echo "ERROR: no plain manifests found under k8s/ — expected at least the landing page and test-app manifests" >&2
  status=1
else
  if ! kubeconform -summary "${SCHEMA_LOCATIONS[@]}" "${plain_manifests[@]}"; then
    status=1
  fi
fi

exit "$status"

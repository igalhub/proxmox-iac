#!/usr/bin/env bash
# Shared chart inventory for every k8s/<component>/values.yaml this repo
# holds for a remote Helm chart. Sourced by both helm-lint-values.sh and
# validate-manifests.sh so the two scripts can't silently diverge again —
# PX-032 found alertmanager/argocd/longhorn/metallb/minio had zero lint
# coverage for months because helm-lint-values.sh kept its own separate
# copy of this list and was never updated when those charts were added.

# shellcheck disable=SC2034 # consumed by scripts that `source` this file
declare -A CHART_REPOS=(
  [ingress-nginx]="https://kubernetes.github.io/ingress-nginx"
  [sealed-secrets]="https://bitnami.github.io/sealed-secrets"
  [bitnami]="https://charts.bitnami.com/bitnami"
  [postgres-operator-charts]="https://opensource.zalando.com/postgres-operator/charts/postgres-operator"
  [prometheus-community]="https://prometheus-community.github.io/helm-charts"
  [grafana]="https://grafana.github.io/helm-charts"
  [jenkins]="https://charts.jenkins.io"
  [metallb]="https://metallb.github.io/metallb"
  [longhorn]="https://charts.longhorn.io"
  [minio-official]="https://charts.min.io/"
  [argo]="https://argoproj.github.io/argo-helm"
)

# shellcheck disable=SC2034 # consumed by scripts that `source` this file
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
  [alertmanager]="prometheus-community/alertmanager"
  [metallb]="metallb/metallb"
  [longhorn]="longhorn/longhorn"
  [minio]="minio-official/minio"
  [argocd]="argo/argo-cd"
)

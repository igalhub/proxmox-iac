# k8s/ — Helm values, manifests, ArgoCD app defs

Per `docs/SPEC.md` §7 build order, ArgoCD retrofit (step 8) happens
*after* the core services are stable — everything here is currently
applied via plain `helm install`/`kubectl apply`, not GitOps yet. This
directory is the record of exactly what was installed and how, so it
can be retrofitted under ArgoCD later without reverse-engineering it.

## What's installed (PX-009)

| Component | Namespace | Install |
|---|---|---|
| nginx-ingress | `ingress-nginx` | `helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace -f k8s/nginx-ingress/values.yaml` |
| Sealed Secrets controller | `kube-system` | `helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system -f k8s/sealed-secrets/values.yaml` |
| Redis | `redis` | `helm install redis bitnami/redis -n redis -f k8s/redis/values.yaml` (namespace + `k8s/redis/redis-auth-sealedsecret.yaml` applied first) |
| Postgres Operator | `postgres-operator` | `helm install postgres-operator postgres-operator-charts/postgres-operator -n postgres-operator --create-namespace -f k8s/postgres-operator/values.yaml` |
| Postgres cluster | `postgres` | `kubectl apply -f k8s/postgres-operator/postgresql-cr.yaml` (namespace created first) |

Helm repos used:
```
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
```
(Note: the sealed-secrets repo moved from `bitnami-labs.github.io` to
`bitnami.github.io` in June 2026 — the old URL 404s.)

## Sealing a new secret

`kubeseal` must match the controller's version (`0.38.4` as of PX-009 —
check via `kubectl -n kube-system get deploy sealed-secrets -o
jsonpath='{.spec.template.spec.containers[0].image}'`, download the
matching release from
https://github.com/bitnami/sealed-secrets/releases).

```
kubectl create secret generic <name> -n <namespace> \
  --from-literal=<key>=<value> --dry-run=client -o yaml | \
kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system \
  --format yaml > k8s/<component>/<name>-sealedsecret.yaml
```

The resulting `SealedSecret` YAML is safe to commit — only the
in-cluster controller (holding the private key) can decrypt it back
into a real `Secret`. The plaintext original is never written to disk.

## Postgres: why 1 instance, not 2

`docs/SPEC.md`'s operator rationale uses a 2-node example. The real CR
here (`k8s/postgres-operator/postgresql-cr.yaml`) uses
`numberOfInstances: 1` — a deliberate trade-off against the host's
resource budget (`docs/SPEC.md` §3), not a limitation of the pattern.
The operator's actual value (Patroni-managed instances, CR-driven
user/db provisioning, leader-election machinery) applies identically at
N=1; scaling to HA is a one-line CR change, not an architecture change.

## Node placement

nginx-ingress, Redis, and Postgres are all pinned to `wk-1` via
`nodeSelector`/`nodeAffinity`, matching `docs/SPEC.md`'s role split —
isolated from `wk-2`'s Jenkins builds (the spikiest load in the
cluster). The Sealed Secrets controller and Postgres Operator itself
aren't pinned; the scheduler placed them on `wk-2`, which is fine —
they're lightweight control-plane-style components, not part of the
app-facing set the SPEC explicitly calls out for placement.

## What's installed (PX-010)

| Component | Namespace | Install |
|---|---|---|
| kube-state-metrics | `monitoring` | `helm install kube-state-metrics prometheus-community/kube-state-metrics -n monitoring --create-namespace -f k8s/kube-state-metrics/values.yaml` |
| node-exporter | `monitoring` | `helm install node-exporter prometheus-community/prometheus-node-exporter -n monitoring -f k8s/node-exporter/values.yaml` (DaemonSet, all 3 nodes) |
| Prometheus | `monitoring` | `helm install prometheus prometheus-community/prometheus -n monitoring -f k8s/prometheus/values.yaml` |
| Grafana | `monitoring` | `helm install grafana grafana/grafana -n monitoring -f k8s/grafana/values.yaml` (`k8s/grafana/grafana-admin-sealedsecret.yaml` applied first) |

Additional Helm repos used:
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
```

**Scope note:** originally planned to extend an existing home-lab
Prometheus/Grafana instance — that instance no longer exists (see
`docs/TICKETS.md` PX-010's scope correction). Deployed fresh, in-cluster,
instead. Standalone `prometheus`/`grafana` charts, not the bundled
`kube-prometheus-stack` — the standalone `prometheus` chart bundles
`kube-state-metrics`/`node-exporter` as subcharts by default, disabled
in `k8s/prometheus/values.yaml` to avoid a duplicate install since both
are already separate releases (their own placement per the SPEC role
split needed them to be). Alertmanager and pushgateway also disabled —
no on-call to page in a home lab.

Two community Grafana dashboards provisioned via `gnetId` at install
time (`k8s/grafana/values.yaml`): **Node Exporter Full** (1860) for
per-node hardware metrics, **Kubernetes cluster monitoring (via
Prometheus)** (315) for pod/deployment health via kube-state-metrics —
together covering both halves of PX-010's "node/pod health" acceptance
criterion.

Grafana reachable at `http://grafana.lab.test` (add a hosts-file entry
pointing at `wk-1`'s IP, or hit `<node-ip>:<nginx-ingress-nodeport>`
directly with a `Host: grafana.lab.test` header).

## Real architecture gap found during PX-010

`cp-1` had no control-plane taint despite `docs/SPEC.md` §1 documenting
one as "the k3s default" — it isn't; k3s only applies it if
`--node-taint` is explicitly passed at install time, which PX-008's
`k3s-server` role never did. Fixed both live (`kubectl taint`, so the
running cluster matches intent immediately) and at the source
(`ansible/roles/k3s-server/tasks/main.yml`, so a future VM rebuild
doesn't silently lose it again). Full trail in `docs/TICKETS.md` under
**PX-008**, not PX-010 — that's where the actual defect was, even though
PX-010 (node-exporter needing to run on `cp-1` too) is what surfaced it.

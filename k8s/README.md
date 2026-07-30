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

# k8s/ — Helm values, manifests, ArgoCD app defs

Per `docs/SPEC.md` §7 build order, ArgoCD retrofit (step 8) started
after the core services were stable and is now complete: all 10
existing releases (landing page, kube-state-metrics, node-exporter,
Prometheus, Grafana, Jenkins, Postgres operator, Sealed Secrets, Redis,
nginx-ingress) are adopted under ArgoCD — none remain as one-off `helm
install`/`kubectl apply`. This directory is the record of exactly what
was installed and how, so the ArgoCD adoption trail in `docs/TICKETS.md`
PX-015 didn't have to reverse-engineer it.

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

## What's installed (PX-013)

| Component | Namespace | Install |
|---|---|---|
| Jenkins | `jenkins` | `helm install jenkins jenkins/jenkins -n jenkins --create-namespace -f k8s/jenkins/values.yaml` (`k8s/jenkins/jenkins-admin-sealedsecret.yaml` and `k8s/jenkins/jenkins-github-deploy-key-sealedsecret.yaml` applied first) |

Additional Helm repo used:
```
helm repo add jenkins https://charts.jenkins.io
```

Pinned to `wk-2` via `nodeSelector` (controller and the dynamic Kubernetes
build-agent pod template both), grouped with kube-state-metrics/
node-exporter per the SPEC role split — isolated from wk-1's always-on
data services. `kubernetes-credentials-provider` plugin surfaces the
sealed GitHub deploy key as a real Jenkins credential without ever
storing it as plaintext. Full pipeline trigger/agent-strategy trail in
`docs/TICKETS.md` under **PX-013**.

## What's installed (PX-014)

| Component | Namespace | Install |
|---|---|---|
| ghcr.io push credential | `jenkins` | `kubectl apply -f k8s/jenkins/jenkins-ghcr-sealedsecret.yaml` — sealed classic PAT (`write:packages`/`read:packages`), surfaced as a "Username with password" Jenkins credential (`ghcr-push-token`) via `kubernetes-credentials-provider`, same pattern as PX-013's deploy key |
| ghcr.io pull secret | `landing-page` | `kubectl apply -f k8s/landing-page/ghcr-pull-sealedsecret.yaml` — same PAT, sealed as a `kubernetes.io/dockerconfigjson` secret, referenced via `imagePullSecrets` in the Deployment. Reused deliberately rather than minting a second token: classic PATs can't be scoped narrower than repo-unscoped anyway, so a second token wouldn't shrink the actual blast radius, just add a secret to track |
| Landing page namespace/Service/Ingress/Deployment | `landing-page` | `kubectl apply -f k8s/landing-page/` (namespace, service, ingress, deployment) |

**Why a pull secret instead of a public package:** the `ghcr.io`
package defaults to private (inherits the repo's visibility). Considered
making it public instead — simpler, no pull secret — but decided to
keep it private and wire in `imagePullSecrets`. Before deciding, checked
`landing/Dockerfile` and the complete file list under `landing/`
line-by-line: only `requirements.txt`, `main.py`, `templates/index.html`
ever get `COPY`'d in, no `ARG`/`ENV` secrets, no `.env`, no credentials
of any kind baked into any layer — so either choice would have been
safe from a content standpoint; private + pull secret was chosen anyway
as the more conservative default.

Reachable at `http://status.lab.test`. Verified end-to-end, not just
"pod applied": real pod `Running` on `wk-1`, pulled from the private
package via `ghcr-pull-secret` on the first attempt (no
`ImagePullBackOff`), and the page itself returns real live data through
the actual ingress path (3/3 nodes ready, real pod-phase counts, real
memory %) — confirmed by `curl -H "Host: status.lab.test"` against the
real nginx-ingress NodePort.

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

## What's installed (PX-015, done)

| Component | Namespace | Install |
|---|---|---|
| ArgoCD | `argocd` | `helm install argocd argo/argo-cd -n argocd -f k8s/argocd/values.yaml` (`k8s/argocd/argocd-github-deploy-key-sealedsecret.yaml` applied first) |

Additional Helm repo used:
```
helm repo add argo https://argoproj.github.io/argo-helm
```

Pinned to `wk-1` via `global.nodeSelector`, grouped with the other
always-on data/apps services, kept off `wk-2` to avoid contending with
Jenkins builds. Reachable at `http://argocd.lab.test` through
nginx-ingress (server runs `--insecure`, TLS terminated nowhere in this
home lab). Dedicated ed25519 read-only GitHub deploy key, separate from
Jenkins's, sealed as ArgoCD's real repo-credential secret shape
(`Opaque`, labeled `argocd.argoproj.io/secret-type: repository`) — not
a literal `kubernetes.io/ssh-auth` typed secret, contrary to how the
ticket's decision was originally worded; ArgoCD only recognizes repo
credentials in the former shape.

App-of-apps skeleton: one root `Application` (`k8s/argocd/root-app.yaml`,
manual sync) manages one child `Application` per adopted release under
`k8s/argocd/apps/`. Adopted so far, each verified via a real sync with
identical pod UID/restarts/age before and after (no disruptive
reinstall) and the release's actual functional check (not just
resource-identity comparison):

| Adopted release | Application manifest | Adoption method |
|---|---|---|
| Landing page | `k8s/argocd/apps/landing-page.yaml` | Raw manifests, git source pointed straight at `k8s/landing-page/` |
| kube-state-metrics | `k8s/argocd/apps/kube-state-metrics.yaml` | Multi-source: upstream Helm chart pinned to the exact live version (`8.0.0`) + values file from this repo via `ref: values` |
| node-exporter | `k8s/argocd/apps/node-exporter.yaml` | Same multi-source pattern, chart pinned to `4.56.1` — first DaemonSet adopted (vs. Deployments) |
| Prometheus | `k8s/argocd/apps/prometheus.yaml` | Multi-source, chart pinned to the exact live version |
| Grafana | `k8s/argocd/apps/grafana.yaml` | Multi-source, chart pinned to the exact live version |
| Jenkins | `k8s/argocd/apps/jenkins.yaml` | Multi-source, chart pinned to the exact live version |
| Postgres Operator | `k8s/argocd/apps/postgres-operator.yaml` | Multi-source; scoped to the operator's own controller only — the `postgresql` CR/pod it manages was never part of this adoption list |
| Sealed Secrets | `k8s/argocd/apps/sealed-secrets.yaml` | Multi-source; verified beyond pod identity — the controller's keypair Secret confirmed byte-for-byte unchanged, plus a live seal→apply→decrypt round trip post-adoption |
| Redis | `k8s/argocd/apps/redis.yaml` | Multi-source, chart pinned to the exact live version — two StatefulSets/PVCs, PVC identity verified unchanged |
| nginx-ingress | `k8s/argocd/apps/nginx-ingress.yaml` | Multi-source, chart pinned to the exact live version — final and highest-blast-radius adoption, full risk investigation and verification trail in `docs/TICKETS.md` PX-015 |

Every `Application`, including the root, is manual-sync only (no
auto-prune/self-heal) — reconciliation against live state always
requires an explicit, reviewed sync, consistent with every other
state-changing action in this project.

All 10 releases are now adopted — none remain as one-off `helm
install`/`kubectl apply`. Postgres/Redis were deliberately saved for
later in the adoption order (stateful, higher blast radius if an
adoption goes wrong), with nginx-ingress saved for last of all — see
`docs/TICKETS.md` PX-015 decision 4 and the full adoption trail.

## What's installed (PX-020)

| Component | Namespace | Install |
|---|---|---|
| MinIO | `minio` | ArgoCD Application (`k8s/argocd/apps/minio.yaml`), official `minio/minio` chart — not Bitnami's, whose free images no longer resolve (see `docs/SPEC.md` §7) |

First brand-new service installed directly through ArgoCD rather than
adopted from a pre-existing `helm install` (`syncOptions:
CreateNamespace=true` handles namespace creation declaratively). Pinned
to `wk-2`, deliberately not `wk-1` where Postgres itself runs — see
`k8s/minio/values.yaml`'s own comment. Exists solely as the WAL-G backup
target for Postgres's continuous archiving + daily base backups
(`k8s/postgres-operator/postgresql-cr.yaml`'s `spec.env`). Full backup
architecture, retention, stated RPO, and the two real platform issues
hit along the way: `docs/SPEC.md` §7; full verification trail
(real WAL segment + base backup confirmed in the target, real
checksum-verified restore): `docs/TICKETS.md` PX-020.

## What's installed (PX-021)

| Component | Namespace | Install |
|---|---|---|
| MetalLB | `metallb-system` | ArgoCD Application (`k8s/argocd/apps/metallb.yaml`), official chart, layer2 mode |

Also a brand-new direct-through-ArgoCD install, same pattern as MinIO
above. The layer2 config itself (`IPAddressPool`/`L2Advertisement`) is a
*separate* Application (`k8s/argocd/apps/metallb-config.yaml`,
raw manifests from `k8s/metallb/config/`) synced only after `metallb`
is confirmed `Healthy` — MetalLB's own CRDs have to exist before those
CRs can apply. `nginx-ingress`'s Service switched from `NodePort` to
`type: LoadBalancer`, now reachable at a real dedicated address,
`192.168.10.13`, instead of a node IP + random high port. Full rationale
and address verification: `docs/SPEC.md` §4/§8; full sync/verification
trail: `docs/TICKETS.md` PX-021.

## What's installed (PX-022)

| Component | Namespace | Install |
|---|---|---|
| Longhorn | `longhorn-system` | ArgoCD Application (`k8s/argocd/apps/longhorn.yaml`), official chart, storage-hosting components restricted to `wk-1`/`wk-2` via a `longhorn-storage=true` node label |

Another brand-new direct-through-ArgoCD install, same pattern as MinIO/
MetalLB. The `StorageClass` itself (`numberOfReplicas: 2`) is a
*separate* Application (`k8s/argocd/apps/longhorn-config.yaml`, raw
manifest from `k8s/longhorn/config/`), synced only after `longhorn` is
confirmed `Healthy` — same CRDs-before-CRs sequencing as MetalLB.
Postgres and Redis both migrated from `local-path` to this Longhorn
`StorageClass`, each verified via real checksum/data comparison against
the live source before cutover. Full disk-budget numbers, replication-
factor rationale, and migration trail: `docs/SPEC.md` §5;
`docs/TICKETS.md` PX-022.

## What's installed (PX-025)

| Component | Namespace | Install |
|---|---|---|
| Alertmanager | `monitoring` | ArgoCD Application (`k8s/argocd/apps/alertmanager.yaml`), official `prometheus-community/alertmanager` chart — own release, not the `prometheus` chart's bundled subchart (stays disabled, same reasoning as kube-state-metrics/node-exporter) |

Another brand-new direct-through-ArgoCD install, same pattern as MinIO/
MetalLB/Longhorn. Pinned to `wk-1`, grouped with the rest of the
always-on observability stack. Prometheus wired to it via
`server.alertmanagers` (`k8s/prometheus/values.yaml`); two curated
alerting rules (`PodCrashLooping`, `PodNotReady`) live in the same
file's `serverFiles.alerting_rules.yml` — this project uses the
standalone `prometheus` chart, not the Prometheus Operator, so rules
aren't `PrometheusRule` CRDs. Telegram bot token/chat ID sealed
(`k8s/alertmanager/alertmanager-telegram-sealedsecret.yaml`), read by
`telegram_configs`' native `bot_token_file`/`chat_id_file` fields —
never a plaintext value or env-var placeholder in git. Two real bugs
found via actual deployment and fixed (a nonexistent Alertmanager flag,
a false-positive rule caught by the real-trigger test): full trail,
including igalhub's confirmed real Telegram delivery, in
`docs/SPEC.md` §11 and `docs/TICKETS.md` PX-025.

## What's installed (PX-026)

No new components — real Prometheus metrics wired up for four services
that previously exported nothing:

| Service | Mechanism |
|---|---|
| Redis | `metrics.enabled: true` (`k8s/redis/values.yaml`) — Bitnami's `redis_exporter` sidecar, auto-discovered via the chart's own default pod annotations |
| Postgres | `postgres-exporter` sidecar added via the CR's `sidecars` field (`k8s/postgres-operator/postgresql-cr.yaml`) — no dedicated exporter flag exists in the operator's CRD |
| Longhorn | explicit `extraScrapeConfigs` static target (`k8s/prometheus/values.yaml`) — the chart sets no scrape annotations |
| MinIO | same shape as Longhorn — explicit `extraScrapeConfigs` static target; its metrics endpoint turned out to already be auth-open by chart default, not requiring the bearer-token wiring originally assumed |

Full per-service mechanism, corrections found during implementation, and
real verification evidence in `docs/SPEC.md` §12 and
`docs/TICKETS.md` PX-026.

## What's installed (PX-027)

No new components — fixes node-exporter's Prometheus `instance` label
showing raw IPs instead of hostnames (`cp-1`/`wk-1`/`wk-2`), which broke
the Node Exporter Full dashboard's host filter. node-exporter is now
excluded from the shared default annotation-based job
(`k8s/node-exporter/values.yaml`'s `service.annotations` override) and
scraped via its own dedicated `extraScrapeConfigs` job
(`k8s/prometheus/values.yaml`, `role: node` discovery) that sets
`instance` from the real node name. Full trail in `docs/TICKETS.md`
PX-027.

## What's installed (PX-028)

No new components — a hand-authored Grafana dashboard,
"proxmox-iac — project services" (`k8s/grafana/values.yaml`'s
`dashboards.default`), covering PX-026's Redis/Postgres/Longhorn/MinIO
metrics. No community `gnetId` exists for this exact combination of
services, and this Application's Grafana chart source can't reach a
separate JSON file in this repo at Helm-template time (multi-source
Application: chart from its upstream repo, values from this repo via
`ref: values` — Helm's `.Files.Get` only reaches files bundled inside
the chart itself), so the dashboard is embedded via the chart's own
`json:` inline mechanism instead, same file the two PX-010 dashboards
are already declared in. Two panels per service, using metric names
confirmed live rather than assumed. Full trail in `docs/TICKETS.md`
PX-028.

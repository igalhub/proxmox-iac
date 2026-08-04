# SPEC — proxmox-iac

This is a living doc: update it in the same commit as any code change that alters architecture. If the code and this doc disagree, that's a bug in the doc.

Status: architecture decided 2026-07-30. Build order steps 1-9 done
(cluster, core services, observability, Jenkins, landing page, ArgoCD
retrofit, Postgres backups, MetalLB, Longhorn). All 10 existing releases are now managed by ArgoCD
(app-of-apps, manual sync) rather than one-off `helm install`/
`kubectl apply` — see `docs/TICKETS.md` PX-015 for the full adoption
trail. A real, tested Postgres backup story (WAL-G to in-cluster MinIO,
§7) landed via PX-020 — deliberately ahead of PX-022's Longhorn storage
migration, which has since completed: Postgres and Redis both now run
on Longhorn (§5), migrated only after that backup story existed as a
safety net. Ingress now reaches the cluster via a real dedicated
LoadBalancer IP (MetalLB, `192.168.10.13`, §4/§8) rather than a
NodePort, per PX-021. Real-time alerting now exists (Alertmanager +
Telegram, §11) via PX-025 — a crash-looping or unhealthy pod pushes a
notification instead of requiring someone to go look. Live status:
`docs/TICKETS.md`.

---

## 1. Architecture at a glance

```
                         ┌─────────────────────────────────────────┐
                         │         Proxmox VE host (bare metal)      │
                         │   Beelink SER, Ryzen 5 5600H, 30GB RAM    │
                         │                                            │
                         │  ┌──────────┐ ┌──────────┐ ┌───────────┐ │
                         │  │ VM: cp-1 │ │ VM: wk-1 │ │ VM: wk-2  │ │
                         │  │ control  │ │ worker   │ │ worker    │ │
                         │  │ plane    │ │ (data)   │ │ (CI/heavy)│ │
                         │  └────┬─────┘ └────┬─────┘ └─────┬─────┘ │
                         │       └─────────────┴──────────────┘      │
                         │              k3s cluster (flannel CNI)    │
                         │   Prometheus + Grafana deployed in-cluster│
                         │   via Helm — see §1 workload split below  │
                         │   (revised 2026-07-30: the previous       │
                         │   external instance no longer exists)     │
                         └─────────────────────────────────────────┘

  Provisioning flow:
  Terraform (bpg/proxmox provider) ──clones──> cloud-init template ──> 3 VMs
  Ansible ──configures──> users/hardening/containerd/k3s install+join ──> cluster up
  ArgoCD (Helm-sourced Applications) ──reconciles──> Redis, Postgres operator,
    nginx-ingress, Jenkins, Sealed Secrets, kube-state-metrics, node-exporter,
    Prometheus, Grafana, landing page — all 10 under GitOps, manual sync
```

Inside the cluster, workloads are split by role, not spread evenly:

- **cp-1 (control-plane):** runs only the k3s server components (API server, scheduler, controller-manager, embedded SQLite datastore, CoreDNS). No application workloads scheduled here (tainted `node-role.kubernetes.io/control-plane:NoSchedule` — **not** actually a k3s default, contrary to what this line originally said; k3s only applies it if `--node-taint` is passed explicitly at install time. PX-008's role didn't; gap found and fixed during PX-010 — see `docs/TICKETS.md`).
- **wk-1 (data/apps worker):** Postgres (via the Zalando operator), Redis, the landing page, ArgoCD, nginx-ingress controller, **Prometheus + Grafana** (revised 2026-07-30 — grouped here as always-on services, deliberately kept off wk-2 to avoid contending with Jenkins builds; exact fit within wk-1's 8GB to be confirmed at PX-010 implementation time against real in-VM free memory, not assumed).
- **wk-2 (CI/heavy worker):** Jenkins (controller + build agents as ephemeral pods), kube-state-metrics, node-exporter.

This split exists so that if Jenkins runs a heavy build and eats a whole CPU core, it doesn't starve Postgres or the ingress controller.

---

## 2. Why each tool is in the stack

This section exists so every line item below has a one-breath answer to "why this and not X."

**Terraform** — declarative infrastructure provisioning. Instead of clicking "Create VM" in the Proxmox web UI, VM definitions live in `.tf` files: CPU/RAM/disk, network, which template to clone from. Run `terraform plan` to see what would change, `terraform apply` to make it happen. The entire point is that the VMs can be destroyed and recreated identically from the files in this repo — no tribal knowledge locked in a GUI.

**bpg/proxmox provider** — the specific plugin that teaches Terraform how to talk to Proxmox's API. Chosen over the older Telmate/proxmox provider because it's more actively maintained and models more of the Proxmox API surface (cloud-init fields, resource pools) as native Terraform resources rather than opaque string blobs.

**cloud-init** — a standard (not Proxmox-specific) mechanism baked into most Linux cloud images that lets a VM configure itself on first boot: hostname, SSH keys, network, a default user. Terraform sets these values per-VM at clone time via a cloud-init drive, so the same template produces three differently-configured VMs.

**Ansible** — configuration management: given already-running VMs, make their internal state match a declared configuration (packages installed, users created, services running). Terraform's job ends once the VM exists and boots; Ansible's job is everything that happens *inside* the OS after that — hardening SSH, creating a non-root deploy user, installing containerd, installing and joining k3s. Ansible is agentless (runs over SSH), which matches "three home-lab VMs," not a fleet needing a persistent agent.

**k3s** — a lightweight, single-binary Kubernetes distribution from Rancher. Chosen over full upstream `kubeadm`-built Kubernetes because it's a realistic production choice for edge/small deployments (not just a toy), and its resource footprint fits a 30GB host running three VMs plus existing services. One binary is both the control-plane and the node agent, which also makes the Ansible role simpler to reason about and explain.

**Helm** — a package manager for Kubernetes. Instead of hand-writing every Deployment/Service/ConfigMap for something like Jenkins, a Helm "chart" bundles all of that as a templated, versioned package with configurable values. `helm install jenkins jenkins/jenkins -f values.yaml` is the equivalent of `apt install`, but for k8s workloads.

**Zalando Postgres Operator** — an operator is a piece of software that runs inside the cluster and encodes operational knowledge about a specific system, so a human doesn't have to perform it by hand. Instead of a Helm chart producing one static Postgres pod, you define a `postgresql` custom resource ("I want a 2-node Postgres cluster, this much storage"), and the operator's controller loop continuously reconciles reality to match: provisions Patroni-managed Postgres instances, handles leader election/failover, manages users/databases declared in the CR, and can be configured for WAL-E backups. This is a materially deeper story than a Helm chart in an interview, at the cost of more moving parts to understand and debug — which is exactly the trade-off worth taking here.

**Redis (Bitnami Helm chart)** — Redis runs as a straightforward Helm-deployed StatefulSet (primary + replica). No operator here: having two operator-managed stateful systems doesn't teach a materially different lesson than one, and Redis's own value in this stack is mostly "a cache Jenkins/the landing page can use," so simplicity wins.

**nginx-ingress** — an Ingress controller is what turns Kubernetes `Ingress` objects (rules like "requests for jenkins.home.lab go to the jenkins Service") into actual reverse-proxy configuration. k3s ships with Traefik pre-installed as its default; this project disables that (`--disable=traefik` at k3s install time) and installs nginx-ingress instead, because nginx is the more commonly deployed ingress controller industry-wide and demonstrates that choice was deliberate, not just "took the default."

**Jenkins** — the CI/CD server. Deployed via its official Helm chart, given a real job: on every push to this repo, run `terraform validate`, `ansible-lint`, Helm chart linting, and (once GitOps is live) trigger ArgoCD to sync. This is explicitly *not* a decorative Jenkins pod sitting idle — its pipelines are part of this project's own change-management story.

**Prometheus + Grafana (in-cluster, revised 2026-07-30)** — originally planned to extend an existing home-lab instance; that instance turned out to no longer exist (it ran on the old `.6` VM wiped at project start, discovered when trying to actually point PX-010 at it). Deployed fresh, in-cluster, via Helm instead — arguably a better fit for this project's "provisioned as code" story than depending on an external instance anyway. This project adds **kube-state-metrics** (translates Kubernetes object state — pod status, deployment replica counts — into Prometheus metrics) and **node-exporter** (per-node hardware/OS metrics: CPU, memory, disk) as a DaemonSet across the three new VMs; both were originally picked up via Prometheus's default annotation-based discovery, no scrape-config wiring needed at the time. **Correction (PX-027):** that held for kube-state-metrics but not node-exporter long-term — the shared default job never relabeled `instance` to the real node name, so node-exporter now has its own dedicated `extraScrapeConfigs` entry (`k8s/prometheus/values.yaml`, `role: node` discovery) instead, excluded from the shared job via its own `service.annotations` override. Sized deliberately light given the tight remaining RAM headroom (§3) — full `kube-prometheus-stack` (which bundles Alertmanager, multiple exporters, longer default retention) is likely more than this lab needs; a slimmer standalone Prometheus + Grafana pairing is the current plan, confirmed at PX-010 implementation time.

**ArgoCD** — GitOps controller. Watches a path in this Git repo containing Kubernetes manifests/Helm releases and continuously reconciles the live cluster to match what's committed. Chosen over Flux specifically because it ships a web UI: syncing status, diffs between Git and live state, and app health are all visible and clickable, which matters for demoing "yes, this is really GitOps" in an interview rather than describing it.

**Landing page** — a small app (planned: lightweight Python/FastAPI or Node/Express, single container) that queries Prometheus's HTTP query API (`/api/v1/query`) directly and renders cluster health (node count, pod status, resource usage) as a simple live-updating page. Deployed as a normal Deployment + Service + Ingress like any other workload — it's both a real (if small) piece of software in the stack and the visual proof-of-life for the whole project.

---

## 3. Resource budget

Host: AMD Ryzen 5 5600H (6 cores / 12 threads), no GPU. **Confirmed live 2026-07-30** via `free -h`/`qm list`/`pvesm status`/`ip a` on the actual host: 27Gi RAM total, 25Gi free, zero existing VMs (the existing Prometheus/Grafana instance turns out to live on a different physical machine, not this Proxmox host — the original assumption that it shares this host's RAM was wrong). `local-lvm` active with ~793GiB free. `vmbr0` up, carries `192.168.10.50/24`. Sizing below is unchanged (it already fit comfortably even under the old, more conservative 30GB/shared-host assumption) but is now confirmed against real numbers rather than planning defaults.

| VM | vCPU | RAM | Disk | Role |
|---|---|---|---|---|
| cp-1 | 2 | 4 GB | 40 GB | k3s control-plane only, no app workloads scheduled |
| wk-1 | 3 | 8 GB | 60 GB | Postgres (operator), Redis, ArgoCD, nginx-ingress, landing page, Prometheus + Grafana |
| wk-2 | 3 | 8 GB | 60 GB | Jenkins (controller + ephemeral build agents), kube-state-metrics, node-exporter |
| **Total** | **8 vCPU** | **20 GB** | **160 GB** | |

That leaves ~5GB of host RAM headroom (25Gi free minus the 20GB allocated above) for Proxmox itself and burst capacity — tighter than originally assumed, but still workable, and there's no other VM on this host competing for it. 8 allocated vCPUs against 12 physical threads is comfortable over-provisioning for a lab workload where all three VMs peaking simultaneously is unlikely — Jenkins builds (the spikiest load) run on wk-2, isolated from wk-1's always-on services.

Jenkins is explicitly called out as the heaviest *single component* (JVM baseline is non-trivial even idle) — hence its own worker rather than sharing with Postgres/Redis.

---

## 4. Networking

- All three VMs sit on the same bridge (`vmbr0`) as the rest of the home lab, static IPs assigned via cloud-init (not DHCP) so Ansible inventory and Terraform outputs stay stable across reboots.
- Planned IPs: cp-1 `.10`, wk-1 `.11`, wk-2 `.12`. **Confirmed free 2026-07-30**, checked three independent ways: (1) live ICMP ping sweep of `192.168.10.0/24`, (2) ARP table cross-check — catches devices that don't answer ping, e.g. `.3` was silent on ICMP but present in ARP, so ping-only would have missed it; only `.1` (gateway), `.2`, `.3`, `.4`, and `.50` (the Proxmox host) showed any activity, (3) the router's own DHCP client list/static-lease config directly — nothing reserved or leased at `.10`/`.11`/`.12`. All three agree.
- **Structural fix, not just a point-in-time check:** the router's DHCP pool was originally `192.168.10.2`–`.100`, which overlapped the planned static range (and, incidentally, `.50` — the Proxmox host itself has been sitting inside the DHCP pool this whole time, unaffected so far but the same latent risk). Router had no separate address-reservation/exclusion feature, so the pool's start was narrowed to `192.168.10.21`, permanently removing `.2`–`.20` from anything DHCP can hand out. `.10`–`.12` are now structurally unreachable by DHCP, not just observed-empty at a point in time. Devices previously leased at `.2`/`.3`/`.4` will pick up a new address from `.21`–`.100` on their next natural lease renewal — expected, harmless, no action needed. Fully resolved, no longer an open item. **Update:** the same mirrored fix was also applied to `.50` — pool's end address narrowed from `.100` to `.49` (nothing else was active in `.50`–`.100`, so this displaced no other device). DHCP pool is now `192.168.10.21`–`.49`. Both the Proxmox host (`.50`) and the planned cluster (`.10`–`.12`) are structurally outside anything DHCP can ever hand out.
- CNI: k3s default (flannel, VXLAN backend). No case for Cilium/Calico here — flannel is sufficient for a 3-node lab cluster and switching CNIs is not one of the skills gaps this project targets.
- **Ingress entry point: MetalLB (PX-021), not NodePort.** nginx-ingress's Service is `type: LoadBalancer`, backed by MetalLB (layer2 mode — the only mode a single flat bridge like this one supports; BGP needs router support this network doesn't have) via a one-address `IPAddressPool` (`k8s/metallb/config/`). Real dedicated address: `192.168.10.13` — right after wk-2's `.12`, structurally outside the DHCP pool (`.21`-`.49`, above) the same way `.10`-`.12`/`.50` are, confirmed free the same rigorous three-way check: ping sweep (no response), ARP table (no entry), and the router's own DHCP client/static-lease list (confirmed directly by igalhub). DNS/hosts-file entries on Igal's machine map friendly names (`jenkins.lab`, `argocd.lab`, `status.lab`, `grafana.lab`) to this one fixed IP directly — no per-service NodePort lookup needed anymore. **Prior state:** NodePort (`30963`/`31395` on wk-1's own IP) — kept working throughout the MetalLB migration (confirmed side-by-side), superseded rather than removed as a fallback.

---

## 5. Storage

- **Kubernetes StorageClass: Longhorn (PX-022), not `local-path`.**
  Postgres and Redis both started on k3s's built-in
  `local-path-provisioner` (host-path-backed PVs, simple, no extra
  install, but ties a pod's data to whichever node it's scheduled on —
  the original reason this wasn't HA at the storage layer). Migrated to
  Longhorn (distributed, replicated block storage) once a real, tested
  Postgres backup existed as a safety net (PX-020) — deliberately
  sequenced that way, not migrating the storage layer underneath live
  data before a proven way to recover it existed.
- **Disk budget — a real number this project didn't have before
  PX-022:** `docs/SPEC.md` §3 only ever budgeted RAM/vCPU, never disk.
  Confirmed live before choosing a replication factor: wk-1 47GB free
  (19% used), wk-2 50GB free (14% used), both single-disk VMs (no
  separate dedicated disk — Longhorn uses a directory on the existing
  root filesystem, chart default `/var/lib/longhorn`). `cp-1` excluded
  entirely — 34GB free but deliberately workload-free per §1, so only 2
  real storage-candidate nodes exist.
- **Replication factor 2, not 3 — a real, justified decision:** a 3rd
  replica would have nowhere valid to go (cp-1 isn't meant to host
  workloads). Total data in scope (Postgres 2Gi + Redis 2×1Gi ≈ 4Gi)
  costs ~8Gi at factor 2, comfortably under 10% of either node's free
  space — this was never a close call. Longhorn's storage-hosting
  components (`longhorn-manager`, CSI plugin, instance-managers)
  restricted to wk-1/wk-2 via a `longhorn-storage=true` node label
  (applied live via `kubectl label`, not yet codified in Ansible — a
  known gap, tracked so a fresh node rebuild doesn't silently lose it).
- Both migrations (Redis, then Postgres) verified via real checksum/data
  comparison against the live source before cutover, not just "the pod
  started" — full trail in `docs/TICKETS.md` PX-022, including a real
  ArgoCD/Helm-hooks issue hit and fixed (Longhorn's `pre-upgrade` hook
  Job) along the way.

---

## 6. Secrets handling

No Vault in this repo (that story lives in `vault-secrets-demo`). Because ArgoCD pulls from Git, anything committed must not be plaintext. Plan: **Sealed Secrets** (Bitnami) — a controller in-cluster holds a private key; `kubeseal` encrypts a Secret client-side into a `SealedSecret` CR that's safe to commit; only the in-cluster controller can decrypt it back into a real Secret. This is the lightest-weight mechanism that still makes "secrets in a GitOps repo" a defensible answer in an interview, without pulling in a second portfolio project's subject matter.

---

## 7. Backup & disaster recovery (Postgres)

**Mechanism:** the Zalando operator's native WAL-G integration, built
into the Spilo image (`ghcr.io/zalando/spilo-18`) — not a bolted-on
`pg_dump` cron job. Continuous WAL archiving (`archive_command` set
automatically by Spilo to `wal-g wal-push`) plus a daily full base
backup, both configured via `spec.env` on `k8s/postgres-operator/postgresql-cr.yaml`
rather than a separate operator-wide config, so the backup config lives
and versions with the cluster it protects.

**Target: in-cluster MinIO** (`k8s/minio/`), single-node/single-drive —
chosen over an external bucket for the same reason as every other choice
in this repo: no external dependency, no cost, one more real
Helm-deployed component to defend under interview questioning. Deployed
via the official `minio/minio` chart, not Bitnami's — Bitnami's free
`docker.io/bitnami/*` images were pulled behind a paid registry
migration mid-2025 and no longer resolve at all (confirmed directly,
not assumed from a changelog). Pinned to `wk-2`, deliberately not `wk-1`
where Postgres itself runs: colocating the backup target with the
primary would mean a single `wk-1` disk failure destroys both the live
data and its only backup, defeating the entire point of having one.
Real headroom confirmed before deploying (`wk-2`: ~50GB disk free,
~6.4GB RAM available at the time) — MinIO's PVC is sized at 10Gi.

**A real platform gotcha hit and fixed, not glossed over:** Spilo
defaults `WALG_S3_SSE` to `AES256` whenever WAL-G is enabled, assuming a
real S3 endpoint with SSE-S3/KMS support. This in-cluster MinIO has no
KMS configured, so every WAL push and base backup failed until this was
found (via the pod's own logs: `"Server side encryption specified but
KMS is not configured"`) and fixed with the dedicated
`WALG_DISABLE_S3_SSE=true` env var — an empty `WALG_S3_SSE` value does
*not* work, Spilo's `configure_spilo.py` treats any falsy value as
"use the AES256 default."

**Retention/schedule:** `BACKUP_SCHEDULE="0 3 * * *"` (daily, 03:00 UTC)
triggers a full WAL-G base backup via Spilo's own internal cron;
`BACKUP_NUM_TO_RETAIN=3` keeps the 3 most recent base backups (Spilo's
`postgres_backup.sh` prunes older ones, along with their now-unneeded
WAL, automatically on each run) — roughly a 3-day recovery window.
Continuous WAL archiving means point-in-time recovery is possible to any
point covered by retained WAL, not just to a base-backup boundary.

**Stated RPO:** effectively continuous under real write activity — WAL
segments ship as they fill, independent of the daily base-backup
schedule. The honest caveat, named rather than hidden: `archive_timeout`
is not explicitly set, so on a near-idle database a WAL segment might
not fill (and therefore not ship) for a long stretch, meaning worst-case
RPO is unbounded on a database with sparse writes. Not fixed in this
pass — a future refinement (`archive_timeout: 60`-style forced periodic
shipping) is a one-line addition, not an architecture change, and this
lab's actual write pattern doesn't yet justify the extra archiving
overhead.

**Verified, not assumed (full trail in `docs/TICKETS.md` PX-020):** a
real WAL segment confirmed landing in MinIO directly (`mc ls`, not
operator logs); a real base backup triggered and confirmed the same way;
a real restore exercised end-to-end via the operator's native
`spec.clone` mechanism into a throwaway `postgresql` CR — a marker row
seeded on the live cluster, checksummed, and confirmed byte-for-byte
identical (`md5` match) on the restored scratch cluster before it was
torn down.

---

## 8. Build order (agreed, do not skip ahead)

1. ✅ Cloud-init Ubuntu 24.04 template on Proxmox (`qm template`).
2. ✅ Terraform provisions cp-1/wk-1/wk-2 from that template (bpg/proxmox provider).
3. ✅ Ansible bootstraps each VM (hardening, containerd, k3s install/join) — cluster comes up, `kubectl get nodes` green.
4. ✅ nginx-ingress + Redis (Helm) + Postgres (Zalando operator) installed.
5. ✅ kube-state-metrics + node-exporter added; Prometheus + Grafana deployed fresh in-cluster via Helm (revised 2026-07-30 — no existing instance to extend, see §2).
6. ✅ Jenkins (Helm) — done once the rest is stable, since it's the heaviest single component.
7. ✅ Landing page (in-cluster Prometheus API → live metrics), deployed behind nginx-ingress.
8. ✅ ArgoCD installed (Helm, `wk-1`, behind nginx-ingress at `argocd.lab.test`), retrofitting everything from step 4 onward under GitOps management. All 10 existing releases adopted (landing page, kube-state-metrics, node-exporter, Prometheus, Grafana, Jenkins, Postgres operator, Sealed Secrets, Redis, nginx-ingress) — none remain as one-off `helm install`s (see `docs/TICKETS.md` PX-015 for the full adoption trail, including the nginx-ingress admission-webhook risk investigation).
9. ✅ Postgres backups (PX-020) — real, tested WAL-G backup/restore story to in-cluster MinIO (§7). ✅ MetalLB (PX-021) — nginx-ingress switched from NodePort to a real dedicated LoadBalancer IP (`192.168.10.13`, layer2 mode). ✅ Longhorn (PX-022) — Postgres and Redis both migrated from `local-path` to distributed, replicated storage (§5). Stretch: Jenkins pipeline coverage expanded (Sealed Secrets is already done, PX-009).

## 9. Open questions / not yet decided

- ~~Exact static IP assignments~~ — resolved (§4): cp-1 `.10`, wk-1 `.11`, wk-2 `.12`, confirmed free and structurally reserved outside the DHCP pool.
- ~~MetalLB vs plain NodePort for ingress entry point~~ — resolved (PX-021): MetalLB deployed (layer2 mode), nginx-ingress switched to `type: LoadBalancer` with a real dedicated IP (`192.168.10.13`, §4). NodePort superseded, not removed — still functional as a fallback.
- ~~Whether Jenkins build agents run as k8s pods... or a fixed agent~~ — resolved (PX-013): dynamic Kubernetes pod agents via the Jenkins Kubernetes plugin, confirmed ephemeral in practice.
- ~~`igalhub/project-template` scaffold could not be pulled into this repo~~ — resolved (PX-011): Igal pointed at the local checkout (`~/claudecode/projects/project-template`), scaffold reconciled against it. This repo follows the template's `--lang bash` shape (shellcheck, plain git pre-commit hook, no pre-commit-framework/uv dependency) since it's Terraform/Ansible, not Python, extended with Terraform-fmt/validate and ansible-lint CI jobs the template has no opinion on. One gap remains: `.claude/dev-check.sh` couldn't be written directly into this repo (protected path in that session) — delivered separately, needs manual copy-in.

## 10. Terraform state management

**Decision (2026-07-30): local state file (`terraform/terraform.tfstate`), not a remote backend.** This was already the de facto choice from PX-004/PX-005 (nothing else was ever configured), but per PX-006 it's being stated as a deliberate decision with its trade-off named, not left as an unexamined default.

**Why local is acceptable here:** this is a single-operator home lab — one person, one machine, applying Terraform. The two problems a remote backend (S3-compatible bucket, Terraform Cloud, etc.) solves — state locking across concurrent applies from different machines/people, and durability independent of any one disk — don't bite at this scale. Local state does still lock against concurrent applies *from the same machine* (Terraform takes an flock-style lock on the state file itself — observed directly during PX-005: `.terraform.tfstate.lock.info` was present and held for the duration of the real `apply`), so the "no locking" trade-off is narrower than it first sounds: it's "no locking across machines," not "no locking at all."

**The trade-off actually being accepted, named explicitly:** if this machine's disk is lost or the file is deleted, the state is gone — Terraform would no longer know the 3 VMs it created exist, and recovery means either restoring from `terraform.tfstate.backup` (Terraform's own single-generation backup, already present alongside the state file) or manually `terraform import`-ing each resource back into a fresh state file using their known VMIDs (110/111/112). No automated off-machine backup exists for this file. Given the project's own non-goals (no HA, no production DR story for the databases either — see `docs/PRD.md`), this is consistent with the project's general risk posture: real trade-offs accepted deliberately for a lab, not solved because solving them isn't the point of this pass.

**If this project ever needed to scale past single-operator** (a second person applying Terraform, or CI running `terraform apply` directly instead of just `validate`/`plan`), that would be the trigger to revisit this and move to a remote backend with real locking — not before.

**Verified, not assumed:** `.gitignore` already excludes `*.tfstate`/`*.tfstate.*` (confirmed via `git check-ignore -v` against the real state files created during PX-005's apply) and neither file has ever appeared in git history (`git log --all -- terraform/terraform.tfstate` returns nothing).

---

## 11. Alerting & notifications

**Decision (2026-08-01, PX-025): Alertmanager, Telegram-only this
pass.** Motivated by a real, recurring gap named across two prior
tickets, not a hypothetical: PX-023's `terraform apply` implicitly
rebooted wk-1/wk-2 with nobody told, caught only because a human
happened to check `uptime`; that same reboot crash-looped Jenkins for
hours, caught only because igalhub hit a 503 directly. Nothing in this
cluster pushed information anywhere before this — Prometheus/Grafana
(§2) require someone to go look.

**Deployed as its own Helm release** (`k8s/alertmanager/`,
`prometheus-community/alertmanager`), not the `prometheus` chart's
bundled `alertmanager` subchart (stays `enabled: false`) — same
reasoning as kube-state-metrics/node-exporter being separate releases:
this project places services by role, which a bundled subchart's
placement can't express. Pinned to `wk-1`, grouped with the rest of the
always-on observability stack. Direct-through-ArgoCD install, same
pattern as MinIO/MetalLB/Longhorn since PX-015. Prometheus wired to it
via `server.alertmanagers` (the standalone community chart's own
mechanism — this project doesn't use the Prometheus Operator, so
alerting rules live in `serverFiles.alerting_rules.yml`, not
`PrometheusRule` CRDs).

**Rule set — deliberately small, two rules, not a broad initial
sweep:** `PodCrashLooping`
(`kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}`,
`for: 2m`) and `PodNotReady`
(`kube_pod_status_ready{condition="false"}` restricted to pods actually
in the `Running` phase, `for: 10m`). The `Running`-phase restriction
isn't precautionary — real-trigger testing caught `PodNotReady` firing
on a `Completed` one-shot debug pod that would never be `Ready` again
by design, a genuine false positive fixed before this shipped, not a
hypothetical avoided in the abstract.

**Notification channel — Telegram, via `telegram_configs`' native
`bot_token_file`/`chat_id_file` fields**, not the `bot_token`/`chat_id`
inline fields — the bot token and chat ID never touch git either way,
but the file-based fields let the actual secret material live purely in
a mounted `SealedSecret` (`k8s/alertmanager/
alertmanager-telegram-sealedsecret.yaml`), with no plaintext value or
even an env-var placeholder in the committed `values.yaml`. (An earlier
draft tried Alertmanager's own env-var substitution instead — real
deploy against the live cluster showed that mechanism doesn't exist in
this Alertmanager version; the file-based fields are the actual
supported mechanism, confirmed via a throwaway pod before trusting it.)
Chosen over Slack (not installed, no self-hosted equivalent), email
(doesn't push to a phone), ntfy/Mattermost (self-hosted, same
new-app friction as Slack for no better outcome), and WhatsApp (no
native receiver, and the available routes are disproportionate or
against ToS) — Telegram uniquely closes the actual gap this exists for:
a real push notification reaching Igal away from the machine, using an
app already installed, via a receiver native to Alertmanager itself.

**Discord — documented fallback, not implemented.** Originally scoped
as a secondary channel (native `discord_configs` receiver, trivial
webhook setup) but deliberately cut to keep this pass focused on
proving the mechanism end-to-end on one channel first. Recorded as the
known, cheap next step if a second channel is ever wanted — but
desktop-only as currently installed, so it would remain a convenience
channel, not a replacement for Telegram's away-from-the-machine
coverage. PagerDuty/Opsgenie-style on-call tooling is out of scope
entirely — disproportionate machinery for a single-operator lab with no
rotation, same category as this project's existing Vault/HA
control-plane non-goals.

**Verified end-to-end, not assumed from rule syntax being valid:** a
real pod deliberately broken (`k8s/test-app/hello.yaml`,
`command: ["/bin/false"]`), watched through its actual lifecycle to
`CrashLoopBackOff`, through Prometheus picking up the metric, through
the alert going `pending` then `firing` after its real `for` window,
through Alertmanager receiving and dispatching it
(`alertmanager_notifications_total{integration="telegram"}`
incremented, zero failures), to igalhub confirming the real Telegram
message arrived with matching labels/annotations. Full trail:
`docs/TICKETS.md` PX-025.

## 12. Stateful-service metrics export

**Decision (2026-08-02, PX-026): per-service mechanism, not a uniform
one.** Before PX-026, Redis/Postgres/Longhorn/MinIO exported nothing to
Prometheus at all — the two PX-010 dashboards only ever covered
node/pod-level health via node-exporter/kube-state-metrics. Checked
each service's real chart/CRD rather than assuming a single pattern,
since this project has no Prometheus Operator (no `ServiceMonitor`
CRDs) — every mechanism below routes through the standalone
`prometheus` chart's own default scrape config, confirmed by reading
the live `prometheus-server` ConfigMap directly:

- **Annotation-based discovery already exists by default** — the
  chart's stock `kubernetes-pods`/`kubernetes-service-endpoints` jobs
  auto-scrape anything carrying a `prometheus.io/scrape: "true"`
  annotation (+ optional `prometheus.io/port`/`path`). No
  `k8s/prometheus/values.yaml` change was needed for either service
  below that already sets or supports this annotation.
- **Redis** — `metrics.enabled: true` in `k8s/redis/values.yaml` turns
  on the Bitnami chart's `redis_exporter` sidecar (port 9121); the
  chart's own default `metrics.podAnnotations` already sets
  `prometheus.io/scrape`/`port`, so it's picked up automatically.
  Verified: `redis_connected_clients` returns real per-instance values
  for both `redis-master-0` and `redis-replicas-0`.
- **Postgres** — the `postgresql` CRD (`acid.zalan.do/v1`) has **no
  dedicated exporter field**, confirmed against the live CRD schema
  directly rather than assumed. The operator's own documented pattern
  for this is its generic `spec.sidecars` array — added a
  `postgres-exporter` container (`quay.io/prometheuscommunity/postgres-exporter:v0.20.1`)
  reusing the already-existing `app-user...credentials` Secret (no new
  credential minted), plus `spec.podAnnotations` (also a real CRD
  field) to point the same default annotation-based discovery at its
  port 9187. **Also found, deliberately not wired here:** Spilo's
  bundled Patroni already exposes its own native `/metrics` on port
  8008 (`patroni_primary`, `patroni_postgres_running`, xlog-position
  gauges) with zero extra config — a different metric scope
  (replication/HA state, not `pg_stat_*`) than this ticket's own
  connection-count example, and annotation-based discovery only wires
  one port per pod. Left as a named option for a future HA-focused
  dashboard, not implemented. Verified:
  `pg_stat_database_numbackends` returns real non-zero per-database
  connection counts (`app_db`, `postgres`, etc.).
- **Longhorn** — the chart sets no scrape annotations at all (only a
  `metrics.serviceMonitor` block, Operator-only and unused here), so
  its existing `/metrics` endpoint (already running on every
  `longhorn-manager` pod, port 9500, no chart config change) is added
  as an explicit `extraScrapeConfigs` static target in
  `k8s/prometheus/values.yaml` against the stable `longhorn-backend`
  Service DNS name. Verified: `longhorn_replica_state` returns real
  per-volume/per-replica state (not a single "robustness" gauge, as
  originally assumed in the ticket text — this is the real metric
  shape in chart v1.12.0), plus real non-zero `longhorn_disk_usage_bytes`.
- **MinIO** — same shape as Longhorn, no scrape annotations, added via
  `extraScrapeConfigs` against `metrics_path: /minio/v2/metrics/cluster`.
  **Auth correction, found only by checking live pod state, not
  assumed either way:** the ticket flagged MinIO's metrics endpoint as
  possibly needing bearer-token auth: `metrics.serviceMonitor.public`
  gates `MINIO_PROMETHEUS_AUTH_TYPE` in the chart's own template — but
  its **default value is already `true`**, and the live MinIO pod
  already had `MINIO_PROMETHEUS_AUTH_TYPE=public` set before this
  ticket touched anything (pod predates the change). The explicit
  `metrics.serviceMonitor.public: true` added to
  `k8s/minio/values.yaml` is a no-op against current chart behavior —
  kept anyway to pin the decision explicitly rather than depend on an
  undocumented upstream default silently changing later. Verified:
  `minio_cluster_usage_object_total` (218) and `minio_cluster_bucket_total`
  (1) both return real, sane non-zero data.

**Explicitly out of scope for this ticket:** no new Grafana dashboard —
a "project services" dashboard consuming these four services' real
metrics is a named follow-up, not part of PX-026's own acceptance
criteria. Full verification trail: `docs/TICKETS.md` PX-026.

**Follow-up (2026-08-02, PX-028): the "project services" dashboard.**
Hand-authored (no community `gnetId` exists for this exact combination
of services), provisioned the same way as PX-010's two existing
dashboards (`k8s/grafana/values.yaml`'s `dashboards.default`) — but via
the chart's `json:` inline mechanism rather than a separate checked-in
file, since this Application's Grafana chart source has no access to
this repo's own files at Helm-template time (multi-source Application:
chart from its upstream repo, values from this repo via `ref: values`
— Helm's `.Files.Get` only reaches files bundled inside the chart
itself). Two panels per service, using the real metric names PX-026
and this ticket actually confirmed live (not the original ticket's
placeholder guesses): Redis (`redis_connected_clients`,
`redis_memory_used_bytes`), Postgres (`pg_stat_database_numbackends`,
`pg_database_size_bytes`), Longhorn
(`longhorn_replica_state{state="running"}`, `longhorn_disk_usage_bytes`),
MinIO (`minio_cluster_usage_object_total`,
`minio_cluster_usage_total_bytes` — the actual total-bytes-used metric
this ticket wanted for backup-storage-growth tracking, confirmed to
exist rather than assumed). Full verification trail:
`docs/TICKETS.md` PX-028.

## 13. Known monitoring-stack quirks

Two real, investigated-and-confirmed-benign discrepancies found
(2026-08-02, PX-029) while comparing the three live Grafana dashboards
(Node Exporter Full, Kubernetes cluster monitoring, and PX-028's
project-services dashboard) side by side. Documented here so a future
session doesn't reopen either as a mystery or "fix" something that
isn't actually broken.

**Quirk 1 — Node Exporter Full and Kubernetes cluster monitoring
disagree on CPU/memory for the same nodes; not a PX-027 regression.**
Node Exporter Full's memory panels use
`node_memory_MemAvailable_bytes`/`MemTotal_bytes` (the kernel's own
reclaimable-aware estimate) — cp-1 39.0%, wk-1 29.5%, wk-2 26.0%.
Kubernetes cluster monitoring's panels use cAdvisor's root cgroup
`container_memory_working_set_bytes{id="/"}` over `machine_memory_bytes`
(job `kubernetes-nodes-cadvisor`, a job PX-027 never touched) — cp-1
48.0%, wk-1 58.4%, wk-2 50.6%, meaningfully higher across the board.
Root cause: cAdvisor's root-cgroup "working set" accounting doesn't
exclude reclaimable page cache the way `MemAvailable` does — the same
class of "total-minus-free trends high on any healthy Linux box"
measurement gap this project already hit three times for Proxmox's own
gauge (`docs/TICKETS.md` PX-007/PX-016/PX-023), just on the
cAdvisor-vs-node-exporter axis instead of Proxmox-vs-guest. Proxmox's
own PVE UI is a third, separate hypervisor-side measurement, already
covered by that same three-ticket history.

**Quirk 2 — Node Exporter Full's `Job` dropdown still lists the old
`kubernetes-service-endpoints` job with node-exporter's pre-PX-027 IPs;
not currently live.** `node_uname_info{job="kubernetes-service-endpoints"}`
returns empty on a live instant query, and `/api/v1/targets` confirms
only `kube-dns`/`kube-state-metrics` are still scraped under that job —
node-exporter's targets are fully gone from it. The old IPs persist in
the `Job`/`Host` dropdowns only because Grafana's
`label_values(metric, label)` variable query scans the entire retained
index (up to the 7-day retention window), not just currently-live
series — a frozen, historical label value, not active data. Selecting
the old job on that dashboard shows a flat line frozen at whatever it
was right before the PX-027 cutover, not growing data. Self-resolving
once those blocks age out of retention; no action needed. This is the
exact nuance PX-027's own ticket text flagged in advance as expected.

Full verification trail: `docs/TICKETS.md` PX-029.

**Quirk 3 — Proxmox's own memory gauge (UI and `pvesh`) is a confirmed
permanent upstream limitation, not something fixable from this repo;
node-exporter/Grafana is the authoritative source for this cluster's
memory usage, permanently.** Found 2026-08-04 when igalhub reported
Proxmox's CPU/RAM gauges reading significantly higher than the day
before and significantly higher than Grafana's node-exporter dashboard.
Real usage was healthy throughout (node-exporter `MemAvailable`-based,
matching `free -h` inside each guest): cp-1 ~40.0%, wk-1 ~29.7-30.1%,
wk-2 ~26.7%. Proxmox's UI/`pvesh` showed cp-1 ~70.9%, wk-1 ~73.8-77.7%,
wk-2 ~62.4-64.5% — a 30-47 point gap, no actual resource pressure.

Root cause confirmed via a direct QMP query (`qom-get` on each VM's
`balloon0` device, read-only): the guest kernel already reports the
correct, cache-aware number through virtio-balloon's stats channel —
`stat-available-memory` matched node-exporter's `MemAvailable` almost
exactly (cp-1: `2466406400` bytes via QMP vs. `2465214464` via
Prometheus, same instant). **Proxmox's own `pvestatd`/status API never
reads `stat-available-memory` — it only reads `stat-free-memory` (raw
free pages, not reclaimable-cache-aware) into `ballooninfo.free_mem`,**
and that's what both `pvesh` and the web UI gauge are built from. The
correct data exists at the QMP/hypervisor level the entire time;
Proxmox's own product code simply never asks for it.

This corrects the conclusions of three prior tickets (PX-007, PX-016,
PX-023 — each treated this as a guest-side problem and each partially
"fixed" it by coincidence or misattribution) without undoing any of
their actual changes: `qemu-guest-agent` (PX-007) and VM ballooning
`memory.floating` (PX-023) both still provide real, independent value
(guest telemetry access and an actual host-side reclaim mechanism,
respectively) — only the belief that either fixed Proxmox's *display*
was wrong. A small poller reading `stat-available-memory` via QMP and
surfacing it somewhere was considered and rejected: Grafana/node-exporter
already serves as the authoritative, already-correct source for this
exact number, so a second path to the same data would be pure
duplication. Full verification trail: `docs/TICKETS.md` PX-030. Full writeup,
committed at `docs/proxmox-bugzilla-memory-gauge-report.md`, filed
upstream as
[Bug 7882](https://bugzilla.proxmox.com/show_bug.cgi?id=7882)
(`pve`/`Qemu`, Proxmox VE 9.2.3, status `NEW`).

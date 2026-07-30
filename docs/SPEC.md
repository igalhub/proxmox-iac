# SPEC — proxmox-iac

This is a living doc: update it in the same commit as any code change that alters architecture. If the code and this doc disagree, that's a bug in the doc.

Status: architecture decided 2026-07-30. Build order steps 1-7 done
(cluster, core services, observability, Jenkins, landing page). Step 8
(ArgoCD retrofit) is next, not yet scoped in detail. Live status:
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
  Helm + ArgoCD ──deploys──> Redis, Postgres operator, nginx-ingress, Jenkins, landing page
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

**Prometheus + Grafana (in-cluster, revised 2026-07-30)** — originally planned to extend an existing home-lab instance; that instance turned out to no longer exist (it ran on the old `.6` VM wiped at project start, discovered when trying to actually point PX-010 at it). Deployed fresh, in-cluster, via Helm instead — arguably a better fit for this project's "provisioned as code" story than depending on an external instance anyway. This project adds **kube-state-metrics** (translates Kubernetes object state — pod status, deployment replica counts — into Prometheus metrics) and **node-exporter** (per-node hardware/OS metrics: CPU, memory, disk) as a DaemonSet across the three new VMs; Prometheus scrapes both directly since they're now all in the same cluster, no external scrape-config/ServiceMonitor wiring needed. Sized deliberately light given the tight remaining RAM headroom (§3) — full `kube-prometheus-stack` (which bundles Alertmanager, multiple exporters, longer default retention) is likely more than this lab needs; a slimmer standalone Prometheus + Grafana pairing is the current plan, confirmed at PX-010 implementation time.

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
- Ingress traffic reaches nginx-ingress via a NodePort (or MetalLB, stretch — see §7) on wk-1; DNS/hosts-file entries on Igal's machine map friendly names (`jenkins.lab`, `argocd.lab`, `status.lab`) to that node's IP.

---

## 5. Storage

- Kubernetes StorageClass: k3s's built-in `local-path-provisioner` (host-path-backed PVs) for both Postgres and Redis persistent volumes initially. Simple, no extra install, but ties a pod's data to whichever node it's scheduled on — acceptable for a lab, explicitly documented as the reason this isn't HA at the storage layer.
- Stretch/future: Longhorn for actual distributed replicated storage across nodes, if time allows — noted in TICKETS.md as a stretch item, not blocking the main build.

---

## 6. Secrets handling

No Vault in this repo (that story lives in `vault-secrets-demo`). Because ArgoCD pulls from Git, anything committed must not be plaintext. Plan: **Sealed Secrets** (Bitnami) — a controller in-cluster holds a private key; `kubeseal` encrypts a Secret client-side into a `SealedSecret` CR that's safe to commit; only the in-cluster controller can decrypt it back into a real Secret. This is the lightest-weight mechanism that still makes "secrets in a GitOps repo" a defensible answer in an interview, without pulling in a second portfolio project's subject matter.

---

## 7. Build order (agreed, do not skip ahead)

1. ✅ Cloud-init Ubuntu 24.04 template on Proxmox (`qm template`).
2. ✅ Terraform provisions cp-1/wk-1/wk-2 from that template (bpg/proxmox provider).
3. ✅ Ansible bootstraps each VM (hardening, containerd, k3s install/join) — cluster comes up, `kubectl get nodes` green.
4. ✅ nginx-ingress + Redis (Helm) + Postgres (Zalando operator) installed.
5. ✅ kube-state-metrics + node-exporter added; Prometheus + Grafana deployed fresh in-cluster via Helm (revised 2026-07-30 — no existing instance to extend, see §2).
6. ✅ Jenkins (Helm) — done once the rest is stable, since it's the heaviest single component.
7. ✅ Landing page (in-cluster Prometheus API → live metrics), deployed behind nginx-ingress.
8. ArgoCD retrofitted to manage everything from step 4 onward going forward — existing Helm releases migrated under GitOps management rather than left as one-off `helm install`s.
9. Stretch: Longhorn, MetalLB, Jenkins pipeline coverage expanded (Sealed Secrets is already done, PX-009).

## 8. Open questions / not yet decided

- ~~Exact static IP assignments~~ — resolved (§4): cp-1 `.10`, wk-1 `.11`, wk-2 `.12`, confirmed free and structurally reserved outside the DHCP pool.
- ~~MetalLB vs plain NodePort for ingress entry point~~ — resolved in practice: NodePort is what's actually running (Jenkins/Grafana both reachable via the ingress-nginx NodePort). MetalLB remains a stretch item (§7.9) if a real LoadBalancer IP is wanted later.
- ~~Whether Jenkins build agents run as k8s pods... or a fixed agent~~ — resolved (PX-013): dynamic Kubernetes pod agents via the Jenkins Kubernetes plugin, confirmed ephemeral in practice.
- ~~`igalhub/project-template` scaffold could not be pulled into this repo~~ — resolved (PX-011): Igal pointed at the local checkout (`~/claudecode/projects/project-template`), scaffold reconciled against it. This repo follows the template's `--lang bash` shape (shellcheck, plain git pre-commit hook, no pre-commit-framework/uv dependency) since it's Terraform/Ansible, not Python, extended with Terraform-fmt/validate and ansible-lint CI jobs the template has no opinion on. One gap remains: `.claude/dev-check.sh` couldn't be written directly into this repo (protected path in that session) — delivered separately, needs manual copy-in.

## 9. Terraform state management

**Decision (2026-07-30): local state file (`terraform/terraform.tfstate`), not a remote backend.** This was already the de facto choice from PX-004/PX-005 (nothing else was ever configured), but per PX-006 it's being stated as a deliberate decision with its trade-off named, not left as an unexamined default.

**Why local is acceptable here:** this is a single-operator home lab — one person, one machine, applying Terraform. The two problems a remote backend (S3-compatible bucket, Terraform Cloud, etc.) solves — state locking across concurrent applies from different machines/people, and durability independent of any one disk — don't bite at this scale. Local state does still lock against concurrent applies *from the same machine* (Terraform takes an flock-style lock on the state file itself — observed directly during PX-005: `.terraform.tfstate.lock.info` was present and held for the duration of the real `apply`), so the "no locking" trade-off is narrower than it first sounds: it's "no locking across machines," not "no locking at all."

**The trade-off actually being accepted, named explicitly:** if this machine's disk is lost or the file is deleted, the state is gone — Terraform would no longer know the 3 VMs it created exist, and recovery means either restoring from `terraform.tfstate.backup` (Terraform's own single-generation backup, already present alongside the state file) or manually `terraform import`-ing each resource back into a fresh state file using their known VMIDs (110/111/112). No automated off-machine backup exists for this file. Given the project's own non-goals (no HA, no production DR story for the databases either — see `docs/PRD.md`), this is consistent with the project's general risk posture: real trade-offs accepted deliberately for a lab, not solved because solving them isn't the point of this pass.

**If this project ever needed to scale past single-operator** (a second person applying Terraform, or CI running `terraform apply` directly instead of just `validate`/`plan`), that would be the trigger to revisit this and move to a remote backend with real locking — not before.

**Verified, not assumed:** `.gitignore` already excludes `*.tfstate`/`*.tfstate.*` (confirmed via `git check-ignore -v` against the real state files created during PX-005's apply) and neither file has ever appeared in git history (`git log --all -- terraform/terraform.tfstate` returns nothing).

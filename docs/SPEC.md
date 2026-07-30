# SPEC — proxmox-iac

This is a living doc: update it in the same commit as any code change that alters architecture. If the code and this doc disagree, that's a bug in the doc.

Status: architecture decided 2026-07-30, build not yet started beyond the cloud-init template (step 1).

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
                         │                                            │
                         │  ┌──────────────────────────────────────┐│
                         │  │ (existing) Prometheus + Grafana VM     ││
                         │  │  now also scrapes the k3s cluster      ││
                         │  └──────────────────────────────────────┘│
                         └─────────────────────────────────────────┘

  Provisioning flow:
  Terraform (bpg/proxmox provider) ──clones──> cloud-init template ──> 3 VMs
  Ansible ──configures──> users/hardening/containerd/k3s install+join ──> cluster up
  Helm + ArgoCD ──deploys──> Redis, Postgres operator, nginx-ingress, Jenkins, landing page
```

Inside the cluster, workloads are split by role, not spread evenly:

- **cp-1 (control-plane):** runs only the k3s server components (API server, scheduler, controller-manager, embedded SQLite datastore, CoreDNS). No application workloads scheduled here (tainted `node-role.kubernetes.io/control-plane:NoSchedule`, the k3s default).
- **wk-1 (data/apps worker):** Postgres (via the Zalando operator), Redis, the landing page, ArgoCD, nginx-ingress controller.
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

**Prometheus + Grafana (existing, extended)** — already running elsewhere in the home lab; not redeployed. This project adds **kube-state-metrics** (translates Kubernetes object state — pod status, deployment replica counts — into Prometheus metrics) and **node-exporter** (per-node hardware/OS metrics: CPU, memory, disk) as a DaemonSet across the three new VMs, then adds scrape configs/ServiceMonitors so the existing Prometheus picks them up. No new time-series database, no new Grafana instance.

**ArgoCD** — GitOps controller. Watches a path in this Git repo containing Kubernetes manifests/Helm releases and continuously reconciles the live cluster to match what's committed. Chosen over Flux specifically because it ships a web UI: syncing status, diffs between Git and live state, and app health are all visible and clickable, which matters for demoing "yes, this is really GitOps" in an interview rather than describing it.

**Landing page** — a small app (planned: lightweight Python/FastAPI or Node/Express, single container) that queries Prometheus's HTTP query API (`/api/v1/query`) directly and renders cluster health (node count, pod status, resource usage) as a simple live-updating page. Deployed as a normal Deployment + Service + Ingress like any other workload — it's both a real (if small) piece of software in the stack and the visual proof-of-life for the whole project.

---

## 3. Resource budget

Host: 30GB RAM total, AMD Ryzen 5 5600H (6 cores / 12 threads), no GPU. The existing Prometheus/Grafana VM already consumes some of this — **confirm actual free capacity with `free -h` and `qm list` on the host before finalizing sizes below**; these are planning defaults, not yet verified against the live host.

| VM | vCPU | RAM | Disk | Role |
|---|---|---|---|---|
| cp-1 | 2 | 4 GB | 40 GB | k3s control-plane only, no app workloads scheduled |
| wk-1 | 3 | 8 GB | 60 GB | Postgres (operator), Redis, ArgoCD, nginx-ingress, landing page |
| wk-2 | 3 | 8 GB | 60 GB | Jenkins (controller + ephemeral build agents), kube-state-metrics, node-exporter |
| **Total** | **8 vCPU** | **20 GB** | **160 GB** | |

That leaves ~10GB of host RAM headroom for Proxmox itself, the existing Prometheus/Grafana VM, and burst capacity. 8 allocated vCPUs against 12 physical threads is comfortable over-provisioning for a lab workload where all three VMs peaking simultaneously is unlikely — Jenkins builds (the spikiest load) run on wk-2, isolated from wk-1's always-on services.

Jenkins is explicitly called out as the heaviest *single component* (JVM baseline is non-trivial even idle) — hence its own worker rather than sharing with Postgres/Redis.

---

## 4. Networking

- All three VMs sit on the same bridge (`vmbr0`) as the rest of the home lab, static IPs assigned via cloud-init (not DHCP) so Ansible inventory and Terraform outputs stay stable across reboots.
- Planned IPs (adjust to whatever's free in the existing 192.168.10.0/24 range): cp-1 `.10`, wk-1 `.11`, wk-2 `.12`. Confirm no collisions with existing lab devices before applying.
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

1. ✅ Cloud-init Ubuntu 24.04 template on Proxmox (`qm template`) — script delivered, awaiting Igal to run it on the host.
2. Terraform provisions cp-1/wk-1/wk-2 from that template (bpg/proxmox provider).
3. Ansible bootstraps each VM (hardening, containerd, k3s install/join) — cluster comes up, `kubectl get nodes` green.
4. nginx-ingress + Redis (Helm) + Postgres (Zalando operator) installed.
5. kube-state-metrics + node-exporter added; existing Prometheus/Grafana extended to scrape.
6. Jenkins (Helm) — done once the rest is stable, since it's the heaviest single component.
7. Landing page (Prometheus API → live metrics), deployed behind nginx-ingress.
8. ArgoCD retrofitted to manage everything from step 4 onward going forward — existing Helm releases migrated under GitOps management rather than left as one-off `helm install`s.
9. Stretch: Sealed Secrets, Longhorn, MetalLB, Jenkins pipeline coverage expanded.

## 8. Open questions / not yet decided

- Exact static IP assignments (needs a check against the live DHCP range/lab devices).
- MetalLB vs plain NodePort for ingress entry point.
- Whether Jenkins build agents run as k8s pods (Jenkins Kubernetes plugin, dynamic agents) or a fixed agent — leaning dynamic pod agents, to be confirmed at step 6.
- ~~`igalhub/project-template` scaffold could not be pulled into this repo~~ — resolved (PX-011): Igal pointed at the local checkout (`~/claudecode/projects/project-template`), scaffold reconciled against it. This repo follows the template's `--lang bash` shape (shellcheck, plain git pre-commit hook, no pre-commit-framework/uv dependency) since it's Terraform/Ansible, not Python, extended with Terraform-fmt/validate and ansible-lint CI jobs the template has no opinion on. One gap remains: `.claude/dev-check.sh` couldn't be written directly into this repo (protected path in that session) — delivered separately, needs manual copy-in.

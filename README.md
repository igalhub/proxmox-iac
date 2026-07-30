# proxmox-iac

A home-lab Kubernetes cluster (k3s: 1 control-plane + 2 workers) on a single Proxmox host, provisioned entirely as code.

- **Terraform** (bpg/proxmox provider) clones VMs from a cloud-init Ubuntu 24.04 template.
- **Ansible** hardens the VMs and installs/joins k3s.
- **Kubernetes (k3s)** runs Redis, Postgres (via the Zalando operator), nginx-ingress, Jenkins, and a small landing page.
- **ArgoCD** manages deployments from this Git repo (GitOps).
- The home lab's existing Prometheus/Grafana is extended (kube-state-metrics + node-exporter) to monitor the new cluster; the landing page pulls live metrics from Prometheus's API.

## Status

Architecture decided, build not yet started beyond the Proxmox cloud-init template. See `docs/TICKETS.md` for exact progress and `docs/SPEC.md` for the full technical spec (every tool choice explained, resource budget, network/storage layout).

## Repo layout

```
docs/
  PRD.md      — why this project exists, goals, success criteria
  SPEC.md     — technical architecture, living doc (update in the same commit as code)
  TICKETS.md  — ticket-level build tracking
terraform/    — VM provisioning (added in Phase 1)
ansible/      — VM bootstrap + k3s install (added in Phase 2)
k8s/          — Helm values / manifests / ArgoCD app definitions (added from Phase 3 onward)
scripts/      — one-off host scripts (e.g. cloud-init template build)
```

## Conventions

- No direct commits to `master`; one branch + one PR per distinct change type; CI green before merge.
- `docs/SPEC.md` is updated in the same commit as any change that affects architecture.
- `HANDOFF.md` (gitignored, not in this repo listing) tracks session-to-session state — current ticket, last action, next step, blockers.
- Repo is private until explicitly made public.

See `CLAUDE.md` for the PM/Developer/QA workflow this repo follows.

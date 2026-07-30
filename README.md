# proxmox-iac

A home-lab Kubernetes cluster (k3s: 1 control-plane + 2 workers) on a
single Proxmox host, provisioned entirely as code.

---

## What This Does

Terraform (bpg/proxmox provider) clones VMs from a cloud-init Ubuntu 24.04
template. Ansible hardens the VMs and installs/joins k3s. Inside the
cluster: Redis (Helm), Postgres (Zalando operator), nginx-ingress,
Jenkins, and a small landing page, all eventually managed by ArgoCD from
this repo (GitOps). The home lab's existing Prometheus/Grafana is
extended (kube-state-metrics + node-exporter) to monitor the new cluster
rather than standing up a redundant monitoring stack.

This exists to close a specific, named gap from recent job rejections
(Terraform/Ansible production depth) with a real, defensible artifact —
see `docs/PRD.md` for the full why.

---

## Project Structure

```
docs/         # PRD.md (why), SPEC.md (architecture, living doc), TICKETS.md
terraform/    # VM provisioning (Phase 1 — not started yet)
ansible/      # VM bootstrap + k3s install (Phase 2 — not started yet)
k8s/          # Helm values / manifests / ArgoCD app defs (Phase 3+)
scripts/      # one-off host scripts (e.g. cloud-init template build)
hooks/        # tracked pre-commit hook source
.github/      # CI workflows
.claude/      # Claude Code adapter scripts (dev-check.sh)
```

## Status

Architecture decided (see `docs/SPEC.md`), build not yet started beyond
the Proxmox cloud-init template script. Live progress: `docs/TICKETS.md`.

## Setup

No language runtime to install — this repo's tooling is Terraform,
Ansible, and Helm, plus a couple of bash scripts.

```bash
# one-time, per machine you run this from:
brew install terraform ansible helm kubectl   # or your OS equivalent

# lint everything this repo currently has:
make lint

# install the local pre-commit hook (shellcheck on staged .sh files):
make install-hooks
```

## Development Workflow

Ticket-based PM/Developer/QA workflow — see `CLAUDE.md` for the full
version. In short: one ticket at a time from `docs/TICKETS.md`, one
branch + one PR per ticket, no direct commits to `master`, CI green
before merge, QA verifies independently before a ticket is marked done.
Session state tracked in `HANDOFF.md` (gitignored, machine-local).

## Claude Code adapter script

`.claude/dev-check.sh` reports which of this project's tooling/services
are present (terraform/ansible/kubectl/helm binaries, Proxmox host
reachability, whether a k3s cluster is currently reachable) — used by the
`/dev-check` global command (see `claude-config`).

## CI

GitHub Actions runs shellcheck on every push/PR to `master`. Terraform
fmt/validate and ansible-lint jobs are wired in already but no-op cleanly
until `terraform/` and `ansible/` exist (Phases 1 and 2) — they activate
automatically, no CI edit needed when those phases land.

## License

Private — not licensed for reuse or redistribution.

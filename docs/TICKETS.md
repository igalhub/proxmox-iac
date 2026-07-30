# TICKETS — proxmox-iac

One branch + one PR per ticket. No bundling unrelated changes. CI green before merge. Shellcheck any bash before merging.

## Status key
`[ ]` not started · `[~]` in progress · `[x]` done

---

### Phase 0 — Foundations
- [x] T0.1 — Repo scaffold: README.md, CLAUDE.md, docs/{PRD,SPEC,TICKETS}.md, .gitignore, HANDOFF.md
- [ ] T0.2 — CI skeleton: GitHub Actions workflow that at minimum runs `terraform fmt -check`, `terraform validate`, `ansible-lint`, shellcheck
- [x] T0.3 — Cloud-init Ubuntu 24.04 template on Proxmox (`build-cloud-init-template.sh`) — script written, **awaiting Igal to run on host and confirm**

### Phase 1 — Terraform (VM provisioning)
- [ ] T1.1 — `terraform/` module skeleton: providers.tf (bpg/proxmox), variables.tf, outputs.tf
- [ ] T1.2 — VM resource definitions for cp-1, wk-1, wk-2 (clone from template, cloud-init per-VM config: hostname, static IP, SSH key)
- [ ] T1.3 — `terraform plan`/`apply` dry run against real Proxmox host, confirm 3 VMs boot and are SSH-reachable
- [ ] T1.4 — Remote state decision (local state file vs. something like a Proxmox-hosted/self-managed backend) — document choice in SPEC.md

### Phase 2 — Ansible (bootstrap + k3s)
- [ ] T2.1 — Inventory (static, matching Terraform outputs) + ansible.cfg
- [ ] T2.2 — Role: common/hardening (non-root deploy user, SSH hardening, unattended-upgrades or equivalent, ufw baseline)
- [ ] T2.3 — Role: containerd (k3s bundles its own containerd, so confirm whether this role is even needed vs. relying on k3s's embedded runtime — resolve before writing)
- [ ] T2.4 — Role: k3s-server (installs on cp-1 with `--disable=traefik`, captures join token)
- [ ] T2.5 — Role: k3s-agent (installs on wk-1/wk-2, joins using cp-1's token)
- [ ] T2.6 — End-to-end run: `kubectl get nodes` from a clean Terraform apply shows 3 Ready nodes with zero manual steps

### Phase 3 — Core services
- [ ] T3.1 — nginx-ingress via Helm, Traefik confirmed disabled, test route works
- [ ] T3.2 — Redis via Bitnami Helm chart
- [ ] T3.3 — Zalando Postgres Operator installed, one `postgresql` CR provisioned, connection verified from a test pod
- [ ] T3.4 — Sealed Secrets controller installed; at least one real secret (Postgres credentials) sealed and committed instead of left in plaintext values files

### Phase 4 — Observability
- [ ] T4.1 — kube-state-metrics + node-exporter deployed to new cluster
- [ ] T4.2 — Existing home-lab Prometheus scrape config updated to include new targets
- [ ] T4.3 — Grafana dashboard (existing instance) showing new cluster's node/pod health

### Phase 5 — Jenkins
- [ ] T5.1 — Jenkins via Helm, sized per SPEC.md budget, on wk-2
- [ ] T5.2 — Pipeline #1: on push to this repo, run terraform validate + ansible-lint + helm lint
- [ ] T5.3 — Pipeline #2: build/test the landing page container image
- [ ] T5.4 — Decide + implement Jenkins build agent strategy (dynamic k8s pod agents vs static)

### Phase 6 — Landing page
- [ ] T6.1 — App skeleton (language/framework TBD at this ticket) querying Prometheus HTTP API
- [ ] T6.2 — Containerize, Helm chart or plain manifests, deploy behind nginx-ingress
- [ ] T6.3 — Jenkins pipeline builds and pushes the image; deploy step wired to GitOps path once Phase 7 lands

### Phase 7 — GitOps retrofit
- [ ] T7.1 — ArgoCD installed
- [ ] T7.2 — Existing Helm releases (Redis, Postgres operator CR, nginx-ingress, Jenkins, landing page) migrated to ArgoCD-managed Applications
- [ ] T7.3 — Prove the loop: commit a change to a values file, confirm ArgoCD syncs it without manual `kubectl`/`helm` intervention

### Stretch (post-MVP, not blocking)
- [ ] S.1 — Longhorn distributed storage, replacing local-path for Postgres/Redis PVs
- [ ] S.2 — MetalLB for a real LoadBalancer IP instead of NodePort
- [ ] S.3 — Diff hand-built scaffold against real `igalhub/project-template` once GitHub access is available; reconcile differences
- [ ] S.4 — Postgres backup story (WAL-E/WAL-G) via the Zalando operator

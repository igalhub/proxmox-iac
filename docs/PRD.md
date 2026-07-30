# PRD — proxmox-iac

## What this is

A home-lab Kubernetes cluster (k3s, 1 control-plane + 2 workers) running on a single Proxmox host, provisioned entirely as code: Terraform creates the VMs, Ansible configures them and installs k3s, and everything that runs inside the cluster (Redis, Postgres, Jenkins, ArgoCD, a metrics landing page) is deployed via Helm and/or GitOps rather than by hand.

## Why this exists

Igal has been rejected from several roles (Cast AI, Rhino Federated Computing, WalkMe) where the feedback pointed at the same gap: not enough demonstrated depth in Terraform and Ansible at a "real infrastructure" level, as opposed to following a tutorial once. This project exists to close that gap with a genuine artifact: infrastructure he built, can explain line by line, and can talk through in an interview — not a toy repo that only proves he can copy-paste a getting-started guide.

The bar for "done" isn't "it runs." It's "I can defend every decision in this repo under interview-style questioning": why bpg/proxmox over Telmate, why an operator for Postgres instead of a Helm chart, why nginx-ingress instead of the Traefik that ships free with k3s, what happens if a worker node dies, how a secret gets from Git to a running pod without ever being committed in plaintext.

## Goals

- Stand up a real (if small) multi-node Kubernetes cluster from bare Proxmox, with zero manual `kubectl create` or SSH-and-hand-edit steps once Terraform/Ansible have run.
- Cover the two specific gaps called out in feedback: Terraform (provisioning) and Ansible (configuration management), each doing real work, not a single trivial resource.
- Run stateful services (Redis, Postgres) the way they'd actually be run in production, including the operator pattern for Postgres.
- Wire the new cluster into GitOps (ArgoCD) so that "how do you deploy changes" has a real answer: push to Git, ArgoCD reconciles.
- Extend the existing Prometheus/Grafana install (already running elsewhere in the home lab) to scrape this cluster, rather than standing up a redundant monitoring stack.
- Give Jenkins actual work to do: building/testing/deploying this project's own components, so it's not an idle pod.
- Ship a small landing page that pulls live metrics from Prometheus, so the project has a visual "here's proof it's alive" artifact for a portfolio link or interview screen-share.

## Non-goals (for this pass)

- High availability at the Kubernetes control-plane level (single control-plane node is accepted; documented as a known limitation, not solved here).
- Full secrets-management platform (Vault) — that's already a separate portfolio project (`vault-secrets-demo`) and conflating the two would blur both stories. This repo will note where a real org would plug in Vault, and use a lighter mechanism (Sealed Secrets or SOPS) for anything that must be Git-committed.
- Multi-node Proxmox / cross-host scheduling — one Proxmox host, three VMs on it.
- Production-grade backup/DR for the databases — noted as a stretch/future item, not blocking.

## Success criteria

- `terraform apply` from a clean Proxmox host produces three running VMs matching spec, with no manual intervention.
- `ansible-playbook` against those VMs produces a working k3s cluster (`kubectl get nodes` shows 1 ready control-plane + 2 ready workers) with no manual steps.
- Redis and Postgres are reachable from inside the cluster, Postgres via the Zalando operator's CRD, Redis via Helm.
- A commit to the GitOps-tracked path in this repo results in ArgoCD applying the change without any `kubectl apply` by hand.
- The existing home-lab Grafana shows live node/pod metrics for the new cluster within a dashboard, sourced from kube-state-metrics + node-exporter running on the new nodes.
- Jenkins has at least one working pipeline that does something real for this repo (e.g., `terraform validate` + `ansible-lint` + a Helm chart lint/test on every push).
- The landing page, reachable via the ingress, shows live-updating cluster health pulled from Prometheus's HTTP API.
- Every architectural decision in `docs/SPEC.md` has a one- or two-sentence "why" that Igal can say out loud without looking it up.

## Constraints

- Hardware: single Beelink SER mini PC, AMD Ryzen 5 5600H (6c/12t), 30GB RAM, no GPU. All sizing decisions must fit inside this budget alongside the pre-existing Prometheus/Grafana VM.
- Repo starts private; standard doc/branching conventions apply (see root `README.md` and `CLAUDE.md`).
- Build order is fixed and agreed (see `docs/SPEC.md` §Build Order) — no skipping ahead to GitOps or Jenkins before the cluster itself is stable.

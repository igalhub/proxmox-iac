# Interview walkthrough — proxmox-iac, step by step

This is the plan explained the way igalhub would walk an interviewer
through it: what's being built, why each decision was made, and in what
order. Not a spec (see `docs/SPEC.md` for that) — a rehearsed narrative
for defending the project under questioning.

---

## The story you're telling

"I built a home-lab Kubernetes cluster from bare metal, entirely as
code — no manual `kubectl create`, no clicking around the Proxmox UI.
Terraform provisions the VMs, Ansible configures them and stands up k3s,
then Helm and ArgoCD deploy everything that runs inside it." That
sentence is the whole pitch. Everything below is being able to back up
every clause in it.

---

## Step 0 — Why this exists (the framing, say this first)

Feedback from Cast AI, Rhino, and WalkMe boiled down to: *not enough
depth in Terraform and Ansible*. This project is a direct response — not
"I followed a tutorial," but "I made real architectural decisions and
can defend each one." Every tool choice in this repo has a documented
one-breath justification (in `docs/SPEC.md`). An interviewer testing
depth will ask "why X and not Y" — never answer "that's what the
tutorial used."

---

## Step 1 — Cloud-init template (PX-003, script done, not yet run)

**What it is:** A Proxmox "VM template" — a golden, un-booted VM image
marked read-only that Terraform will *clone* to create real VMs, instead
of installing an OS from scratch every time.

**How:** `qm create` a shell VM, `qm importdisk` an official Ubuntu 24.04
cloud image into it, attach a cloud-init drive (a virtual CD-ROM Proxmox
injects config through on first boot), set boot order and the QEMU guest
agent, resize the disk, then `qm template` to lock it as a template
(VMID 9000).

**Why cloud-init specifically:** it's not a Proxmox trick — it's a
standard mechanism baked into virtually every cloud Linux image, used
identically on AWS/GCP/Azure/bare Proxmox. It lets a VM configure itself
at first boot: hostname, SSH keys, static IP, a default user — all
injected externally, without ever touching the disk image itself.
That's the mechanism that lets one template produce three *differently
configured* VMs.

**Why the template doesn't set a user/SSH key itself:** identity is
deliberately left to Terraform at clone time — the template is generic,
dumb, and reusable; per-VM identity is provisioning's job, not the
template's.

**Status:** script exists (`scripts/build-cloud-init-template.sh`),
hasn't been run yet on the physical host (`192.168.10.50`). This is the
literal first domino — nothing downstream can start until this template
exists.

---

## Step 2 — Terraform module skeleton (PX-004)

**What it is:** `terraform/providers.tf`, `variables.tf`, `outputs.tf` —
no VM resources yet, just proving Terraform can authenticate against the
Proxmox API.

**Why do this before writing VM resources:** classic "prove the plumbing
before building on it" — `terraform plan` against zero resources should
run clean, meaning the provider is correctly configured and can reach
the API, before adding anything that could fail for a *different* reason
(auth vs. resource definition) and confuse debugging.

**The provider — `bpg/proxmox`:** this is the plugin that teaches
Terraform Proxmox's API dialect. Chosen over the older `Telmate/proxmox`
provider because it's more actively maintained and models more of
Proxmox's surface (cloud-init fields, resource pools) as first-class
Terraform resources instead of opaque string blobs. If asked "why not
Telmate" — maintenance and API fidelity.

**The API token:** generated in the Proxmox web UI — Datacenter →
Permissions → API Tokens — scoped to whatever's minimally needed (VM
create/clone/config, not full root). It's a `user@realm!tokenid=secret`
pair. This must never touch git: it lives in a `terraform.tfvars` file,
gitignored (already confirmed in `.gitignore`), with a
`terraform.tfvars.example` committed showing the *shape* of the file
without real values. If asked "how do you keep Terraform credentials out
of source control" — that's the answer, and it's the same pattern (real
secret gitignored, example checked in) used for Ansible vault files
later.

---

## Step 3 — Terraform VM resource definitions (PX-005)

**What it is:** actual VM resources (three: cp-1, wk-1, wk-2), each
cloned from the PX-003 template, each with its own cloud-init overrides
— hostname, static IP, SSH key — and sized per the resource budget in
SPEC.md (cp-1: 2 vCPU/4GB, wk-1 & wk-2: 3 vCPU/8GB each).

**Why static IPs, not DHCP:** the whole point of IaC is reproducibility
— if IPs could shift on reboot, the Ansible inventory (static, matching
Terraform's outputs) would drift out of sync with reality. Static IPs
assigned via cloud-init keep Terraform's world-model and Ansible's
world-model identical.

**Success criterion:** `terraform apply` from a clean host produces
exactly these 3 VMs, all SSH-reachable at their planned IPs, with zero
manual steps afterward. That "zero manual steps" clause is the whole
thesis of the project.

---

## Step 4 — Terraform state decision (PX-006)

**What it is:** a deliberate, *documented* decision — local `.tfstate`
file vs. a remote backend (S3-compatible, Terraform Cloud, etc.) — not a
default left unexamined.

**Why this gets its own ticket:** state is the thing that tells Terraform
what it already created. Losing it, or applying concurrently against
stale state, is a classic Terraform failure mode. For a single-operator
home lab, local state is the pragmatic choice — but the trade-off (no
locking, no automatic backup, single point of failure if the disk dies)
has to be named out loud. "I know the trade-off and accepted it
deliberately" is a materially different answer than "I didn't think
about it."

---

## Step 5 — Ansible inventory + roles skeleton (PX-007)

**What it is:** `ansible/inventory` (static, mirrored from Terraform's
outputs), `ansible.cfg`, and role skeletons: `common`/hardening,
`k3s-server`, `k3s-agent`.

**Why Ansible and not something else for this layer:** Terraform's job
ends the moment a VM exists and boots — it doesn't know or care what's
happening *inside* the OS. Ansible's job starts there: given
already-running machines, make their internal state (packages, users,
running services) match a declared configuration. This is the classic
provisioning/configuration-management split, and it's a deliberate line.

**Why Ansible specifically (agentless) for 3 VMs:** Ansible runs over
plain SSH — no persistent agent installed on the managed nodes. That fits
"three home-lab VMs" much better than something like Puppet/Chef, which
assume a fleet large enough to justify a running agent and a central
master. If asked "why not Puppet" — the honest answer is scale:
agentless-over-SSH is the right tool at this fleet size.

**Open design question resolved before writing the role:** whether a
separate `containerd` role is needed, or whether k3s's *embedded*
containerd makes that redundant. (It does — k3s ships and manages its own
containerd; a separate role would be duplicate work.)

---

## Step 6 — k3s cluster bring-up (PX-008)

**What it is:** the `k3s-server` role installs on cp-1 with
`--disable=traefik` (explained below), captures the join token k3s
generates; the `k3s-agent` role installs on wk-1/wk-2 and joins using
that token.

**Why k3s over full upstream Kubernetes (`kubeadm`):** k3s is a single
binary bundling both control-plane and node-agent — a genuinely realistic
production choice for edge/small deployments (Rancher built it for
exactly that), not a toy simplification. Its footprint fits a 30GB host
that's also running two other VMs' worth of workload, and a single
binary makes the Ansible role simpler to reason about and explain than
juggling `kubeadm init`/`kubeadm join` plus a separate CNI install step.

**`--disable=traefik` — say this precisely if asked:** k3s ships Traefik
as its *default* ingress controller. This project explicitly disables it
at install time and installs nginx-ingress instead (step 8), so the
choice reads as deliberate rather than "I just used whatever came in the
box."

**Success criterion:** `kubectl get nodes` shows exactly 3 Ready nodes (1
control-plane, 2 workers), and — critically — a *clean run* of
`terraform apply` followed by `ansible-playbook` produces this with zero
manual intervention. That end-to-end claim is the actual deliverable of
Phases 1–3 combined.

---

## Step 7 — Core services (PX-009): ingress, Redis, Postgres, Sealed Secrets

This is the step with the most "why not the obvious simpler choice"
surface area — worth rehearsing carefully.

- **nginx-ingress (Helm):** turns Kubernetes `Ingress` objects (routing
  rules like "requests for `jenkins.lab` go to the jenkins Service")
  into actual reverse-proxy config. Chosen over the pre-installed Traefik
  because nginx is the more commonly deployed ingress controller
  industry-wide, and installing it explicitly (after disabling Traefik)
  demonstrates the choice was made, not defaulted into.

- **Redis — Bitnami Helm chart, no operator:** a straightforward
  Helm-deployed primary+replica StatefulSet. Deliberately *not* given an
  operator, because running two operator-managed stateful systems
  wouldn't teach a materially different lesson than one — Redis's role
  here is mostly "a cache," so simplicity wins. This contrast (operator
  for one thing, plain Helm for another) signals a judgment call, not
  cargo-culting "operators are always better."

- **Postgres — Zalando Postgres Operator, not a Helm chart:** the
  single highest-value "depth" answer in the whole stack, worth
  over-preparing. A Helm chart for Postgres just stamps out one static
  pod. An *operator* is software running inside the cluster that encodes
  ongoing operational knowledge: you declare a `postgresql` custom
  resource ("I want a 2-node cluster, this much storage"), and the
  operator's controller loop continuously reconciles live state to match
  that declaration — provisioning Patroni-managed instances, handling
  leader election and failover automatically, managing users/databases
  from the CR spec, and it can be wired to WAL-E backups. The honest
  trade-off to state alongside this: more moving parts to understand and
  debug than a static pod — taken deliberately because "I ran a stateful
  system with an operator" is a materially deeper interview answer than
  "I helm-installed Postgres."

- **Sealed Secrets:** the secrets-management piece, deliberately *not*
  Vault. Vault already has its own dedicated portfolio project
  (`vault-secrets-demo`) — conflating the two would blur both stories.
  Here, because ArgoCD pulls from Git (step 9), anything committed must
  never be plaintext. Sealed Secrets solves this with an in-cluster
  controller holding a private key; `kubeseal` encrypts a Secret
  client-side into a `SealedSecret` custom resource that's safe to commit
  to Git — only the in-cluster controller can decrypt it back into a
  real Secret. If asked "how does a secret get from Git to a running pod
  without ever being plaintext in the repo" — that's the exact
  mechanism, in that order.

---

## Step 8 — Observability extension (PX-010)

**What it is:** deploy `kube-state-metrics` (translates Kubernetes
object state — pod status, replica counts — into Prometheus-scrapeable
metrics) and `node-exporter` (per-node hardware/OS metrics: CPU, memory,
disk) onto the three new VMs, then point the *existing* home-lab
Prometheus at them and add a Grafana dashboard.

**Why extend the existing Prometheus/Grafana instead of standing up a
new one:** avoiding a redundant monitoring stack is itself the answer —
one source of truth for metrics across the whole home lab, not a second
silo. The "obvious" move for many people is to bundle a fresh
kube-prometheus-stack; not doing that is a deliberate resource/
architecture call given the 30GB budget.

---

## Step 9 — Jenkins (not yet ticketed in detail)

Deployed last among the heavy components, specifically because it's the
single heaviest component in the resource budget (JVM baseline is
non-trivial even idle) — hence why it gets its own isolated worker
(wk-2), separate from wk-1's always-on Postgres/Redis/ingress, so a build
spike can't starve them. Given real work: on every push, run `terraform
validate` + `ansible-lint` + Helm chart lint, and eventually trigger
ArgoCD syncs. Not a decorative idle Jenkins pod — its pipelines are part
of the project's actual change-management story.

---

## Step 10 — Landing page (not yet ticketed)

A small app (planned Python/FastAPI or Node/Express) that queries
Prometheus's HTTP API directly and renders live cluster health. Deployed
as an ordinary Deployment+Service+Ingress like anything else in the
cluster. Its purpose is explicitly dual: a real (if small) piece of
software running in the stack, and the visual "proof of life" to
screen-share in an interview.

---

## Step 11 — ArgoCD retrofit (not yet ticketed)

**What it is:** ArgoCD watches a path in this Git repo containing
manifests/Helm releases and continuously reconciles the live cluster to
match what's committed. Retrofitted last — everything installed in steps
7–10 as one-off `helm install`s gets migrated *under* ArgoCD's management
rather than staying hand-installed.

**Why ArgoCD over Flux:** ArgoCD ships a web UI showing sync status,
Git-vs-live diffs, and app health, all visible and clickable — which
matters specifically for *demoing* GitOps in an interview rather than
just describing it in words.

**Why this step comes last, not earlier:** the build order is explicitly
fixed to not "skip ahead to GitOps... before the cluster itself is
stable" — avoiding debugging a reconciliation loop and a flaky cluster at
the same time.

---

## Non-goals — know these cold, they preempt a certain kind of question

- **No HA control-plane** — single control-plane node is an accepted,
  documented limitation, not solved here. If asked "what happens if cp-1
  dies" — the honest answer is "the cluster goes down; this is a known,
  accepted trade-off for a lab, and a real answer to 'what would you
  change for production' is multi-master control-plane."
- **No Vault** — deliberately kept in a separate repo to avoid diluting
  either project's story.
- **Single Proxmox host** — no cross-host scheduling; three VMs on one
  box.
- **No production DR for the databases** — noted as future/stretch, not
  solved.

---

## Where things stand right now

Steps 0 (framing) and the doc/CI scaffolding are done. **Step 1 —
running the cloud-init template script on the physical host — is the
next real action**, and it's the one thing blocking every subsequent
step. After that: PX-004 (Terraform skeleton + generating the Proxmox API
token), then PX-005 through the rest in the fixed order above.

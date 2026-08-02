# Interview walkthrough — proxmox-iac, step by step

What's being built, why each decision was made, and in what order. Not a
spec (see `docs/SPEC.md` for that) — a rehearsed narrative for defending
the project under questioning.

---

## The story you're telling

"I built a home-lab Kubernetes cluster from bare metal, entirely as
code — no manual `kubectl create`, no clicking around the Proxmox UI.
Terraform provisions the VMs, Ansible configures them and stands up k3s,
then Helm and ArgoCD deploy everything that runs inside it." That
sentence is the whole pitch. Everything below is being able to back up
every clause in it.

---

## Step 0 — Why this exists (the framing)

This project is a direct response — not "I followed a tutorial," but "I
made real architectural decisions and can defend each one." Every tool
choice in this repo has a documented one-breath justification (in
`docs/SPEC.md`). An interviewer testing depth will ask "why X and not
Y" — never answer "that's what the tutorial used."

---

## Step 1 — Cloud-init template (PX-003, done)

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

**Status:** done. Template VMID 9000 exists on the physical host
(`192.168.10.50`), confirmed via `qm config 9000` showing `template: 1`.
This was the literal first domino — nothing downstream could start until
it existed.

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
disk) onto the three new VMs, plus a fresh, standalone Prometheus +
Grafana via Helm, in-cluster, with two provisioned dashboards.

**Why in-cluster instead of extending the home lab's existing
Prometheus/Grafana — say this precisely if asked, the original plan
changed:** the plan going in *was* to extend an existing instance
(`192.168.10.6:30093`), for the same "avoid a redundant monitoring
stack" reasoning. That instance turned out to no longer exist — it ran
on the old `.6` VM, wiped at the start of this project — discovered when
actually trying to point this ticket at it. Rather than standing up a
substitute external dependency, monitoring was brought fully in-scope
and provisioned as code like everything else here. Deliberately *not*
the bundled `kube-prometheus-stack` either — standalone `prometheus`/
`grafana` charts, since the bundle's own kube-state-metrics/node-exporter
subcharts would duplicate the separately-placed releases the SPEC's role
split already calls for.

---

## Step 9 — Jenkins (PX-013, done)

Deployed last among the heavy components, specifically because it's the
single heaviest component in the resource budget (JVM baseline is
non-trivial even idle) — hence why it gets its own isolated worker
(wk-2), separate from wk-1's always-on Postgres/Redis/ingress, so a build
spike can't starve them. Given real work: on every push (detected via
SCM polling — no public ingress for GitHub to webhook into), a real
Jenkinsfile runs `terraform validate` + `ansible-lint` + Helm chart lint
on a dynamic, ephemeral Kubernetes pod agent. Not a decorative idle
Jenkins pod — verified via a genuine SCM-poll-triggered run, not a
manually-invoked one, before this ticket closed.

---

## Step 10 — Landing page (PX-014, done)

A small FastAPI app that queries Prometheus's HTTP API directly at
request time and renders live cluster health (node readiness, pod
status by phase, memory usage) — no hardcoded/mocked data, proven by
scaling a real workload and watching the number change, twice: once
locally before deployment, once against the actually-deployed pod.
Deployed as an ordinary Deployment+Service+Ingress like anything else
in the cluster.

**How the image actually gets built — worth telling in full, it's a
real story:** Jenkins builds and pushes the image itself, via a new
`kaniko` stage — no Docker daemon available in the agent pod, and
kaniko builds/pushes OCI images without one, fitting the same
ephemeral-pod-agent pattern as the rest of the pipeline. Real,
SCM-poll-triggered run confirmed via the Jenkins API (not a manual
build), and the pushed image independently confirmed pullable via
GitHub's own UI, not trusted from a console log line.

**The credential story is the deeper answer if asked "how do you scope
a CI credential":** getting Jenkins a `ghcr.io` push credential surfaced
two real GitHub constraints, found by hitting them, not read in
advance — fine-grained PATs don't support container-registry package
operations at all; classic PATs need the full `repo` scope alongside
`write:packages` specifically *because the repo is private* (GitHub
couples package-write to full repo access for private repos). Accepted
as a named trade-off (`docs/TICKETS.md` PX-014), with a follow-up
ticket (PX-017) to narrow it back down once the repo goes public and
that coupling no longer applies. "I hit a real platform constraint,
named the trade-off, and left a tracked path back to least-privilege"
is a materially better answer than pretending the token was scoped
perfectly from the start.

Its purpose is explicitly dual: a real (if small) piece of software
running in the stack, and the visual "proof of life" to screen-share in
an interview.

---

## Step 11 — ArgoCD retrofit (PX-015, done)

**What it is:** ArgoCD watches a path in this Git repo containing
manifests/Helm releases and continuously reconciles the live cluster to
match what's committed. Retrofitted last — everything installed in steps
7–10 as one-off `helm install`s gets migrated *under* ArgoCD's management
rather than staying hand-installed. Deliberately staged rather than done
in one pass: landing page adopted first (stateless, disposable, lowest
risk if the adoption pattern turned out to be wrong), then two pure
metrics exporters (kube-state-metrics, node-exporter) to prove it again
on a Helm-sourced release and then a DaemonSet, before ever touching
anything stateful. All 10 releases are now adopted.

**Why ArgoCD over Flux:** ArgoCD ships a web UI showing sync status,
Git-vs-live diffs, and app health, all visible and clickable — which
matters specifically for *demoing* GitOps in an interview rather than
just describing it in words.

**Why this step comes last, not earlier:** the build order is explicitly
fixed to not "skip ahead to GitOps... before the cluster itself is
stable" — avoiding debugging a reconciliation loop and a flaky cluster at
the same time.

**The adoption story, if asked "how do you migrate something already
running into GitOps without downtime":** every adoption is verified the
same way — record the live pod's UID/restart count/age *before* the
Application exists, point ArgoCD at the exact same manifests (for a Helm
release, the exact chart version already deployed, so the rendered
output is byte-for-byte identical), sync once, then confirm the pod's
UID/restarts/age are *unchanged*. If they match, ArgoCD only updated
ownership/tracking metadata — it never deleted and recreated anything.
For the two metrics exporters this went one step further: after
adoption, queried Prometheus directly and confirmed the actual scrape
targets were still `up` — the functional check, not just "the resource
looks the same."

**A real bug found and fixed along the way, worth telling if asked "what
went wrong":** after the first adoption, the root `Application` showed a
permanent `OutOfSync` even immediately following a clean sync. Traced it
(not guessed) via ArgoCD's own `managed-resources` diff API: the child
Application manifest declared `directory: {recurse: false}` and
`syncPolicy: {}` explicitly, but ArgoCD's controller persists the live
object *without* those empty/default fields, so Git and live could never
converge. Fixed by dropping the redundant fields (omitting them is
functionally identical). Small bug, but the diagnosis path — reading the
actual API diff instead of assuming "it'll resolve itself" — is the more
interesting answer.

---

## Step 12 — Postgres backups, MetalLB, and Longhorn (PX-020/021/022, done)

**What it is:** three follow-on tickets, deliberately sequenced, landing
after the ArgoCD retrofit rather than folded into it.

- **PX-020 — real Postgres backup/restore.** The Zalando operator's
  native WAL-G integration (continuous WAL archiving + a daily base
  backup) targeting an in-cluster MinIO, not a bolted-on `pg_dump` cron.
  Verified end to end: a real WAL segment and base backup confirmed
  landing in MinIO directly (`mc ls`), and a real restore exercised via
  the operator's `spec.clone` mechanism into a throwaway CR — a marker
  row seeded, checksummed, and confirmed byte-for-byte identical on the
  restored cluster. Hit and fixed a real platform gotcha along the way:
  Spilo defaults to `WALG_S3_SSE=AES256`, which breaks against a
  KMS-less MinIO; the actual fix is the dedicated
  `WALG_DISABLE_S3_SSE=true` flag, found by reading `configure_spilo.py`
  inside the running pod.
- **PX-021 — MetalLB.** Real dedicated `LoadBalancer` IP
  (`192.168.10.13`, layer2 mode) for nginx-ingress, replacing NodePort
  as the entry point (NodePort still works, superseded not removed).
- **PX-022 — Longhorn.** Postgres and Redis migrated from `local-path`
  to Longhorn (distributed, replicated block storage), deliberately
  sequenced *after* PX-020 so a real, tested backup existed as a safety
  net before touching the storage layer under live data. Replication
  factor 2, justified against real disk-headroom numbers (`docs/SPEC.md`
  §5), not assumed. Both migrations verified via checksum/functional
  comparison before cutover, and a real ArgoCD/Helm-hooks issue (a
  hanging `longhorn-pre-upgrade` Job) was hit and fixed along the way.

**Why this order, if asked:** backup before storage migration is the
one dependency worth naming — proving you can recover the data *before*
moving the disk it lives on, not after.

---

## Step 13 — VM ballooning, and a three-ticket root-cause story (PX-023, done)

**What it is:** the Proxmox UI's memory gauge for all three VMs had been
maxed out near 100% since early in the project — cosmetic, never a real
resource problem (`kubectl top nodes` always showed real usage was low),
but worth telling in full because the actual fix took three separate
tickets to reach, each one correcting the last. That arc is a better
answer to "tell me about a bug you had to dig into" than any single
ticket in isolation.

**PX-007 (misdiagnosis #1):** `qemu-guest-agent` was declared in
Terraform (`agent.enabled = true`) but never actually installed by the
Ansible role. Without it, Proxmox had no guest memory data at all and
fell back to a host-side view counting Linux's own disk cache as
"used." Fixed by installing the agent — but the gauge was *still* wrong
afterward, which is where it gets interesting.

**PX-016 (misdiagnosis #2 — looked fixed by accident):** the guest
agent's memory-stat capability only negotiates with Proxmox at VM *boot*
time, not from a live install. A reboot made the gauge accurate — but
that "fix" was actually just resetting the guest's page cache to empty,
which happened to make a still-miscalibrated gauge read correctly for a
few hours. The ticket closed `DONE` on that window without waiting long
enough to see it drift back. It did, weeks later, caught during PX-022.

**PX-023 (the real fix):** ballooning itself was never enabled
(`balloon`/`memory.floating` unset, defaulting to disabled). Without a
real balloon floor, Proxmox has no genuine memory-pressure telemetry
from the guest and falls back to something close to `total - free` —
which trends toward 100% on *any* healthy long-running Linux guest,
since Linux deliberately keeps `free` near zero for reclaimable disk
cache (by design, not a leak). Set a real non-zero `memory.floating` per
VM via Terraform — tighter on cp-1 (87.5% floor) than wk-1/wk-2 (75%)
given cp-1 is the sole control-plane node with no HA and runs etcd.
Verified stable across a real multi-hour post-reboot window (not just
immediately after rebooting) — the specific verification gap that made
PX-016's close premature.

**The honest part, if asked "what went wrong along the way":** applying
the Terraform change itself triggered an *implicit reboot* of wk-1/wk-2
via the provider — not a hot config write, discovered only by checking
`uptime` after the fact and noticing the apply for those two VMs took
6x longer than cp-1's. That reboot happened without the discrete
per-VM go-ahead the plan called for. Documented as a real process
deviation rather than folded quietly into "it worked out" — including a
full stateful-service health check afterward (Longhorn replicas,
Postgres/Redis restart counts, a marker-row/known-key data-integrity
check) to independently confirm nothing was lost, and a named lesson for
future tickets: changes to hardware-affecting VM attributes can trigger
an implicit reboot at `apply` time, so approval needs to happen *before*
apply, not before a separately-scheduled reboot command.

**Why this is worth telling over a cleaner-sounding bug:** it's honest
about getting something wrong twice before finding the real cause, and
about a process slip mid-fix — and shows the discipline of catching both
via direct verification (`uptime`, real API-based memory readings, real
data-integrity checks) rather than trusting an early good-looking
result, which is exactly the mistake that caused PX-016 to close
prematurely in the first place.

---

## Step 14 — Alertmanager, and two real bugs found by actually deploying (PX-025, done)

**What it is:** PX-023's own process-deviation finding (a disruption
that went undetected until a human happened to check `uptime`) and the
Jenkins crash-loop it caused, undetected for hours until igalhub hit a
503 directly — both are the same underlying problem: nothing in this
cluster ever pushed information anywhere. Prometheus/Grafana (Step 8)
require someone to go look. Alertmanager closes that gap: two curated
rules (`CrashLoopBackOff`, `PodNotReady`-for-10m — deliberately small,
not a broad sweep, to avoid trading "nobody notices" for "everyone
tunes it out") wired to Telegram as the sole channel this pass, chosen
specifically because it reaches a phone away from the machine, not just
another place information sits waiting to be checked.

**The two bugs, worth telling in full — this is the deeper answer if
asked "walk me through debugging something that didn't work as
expected":**

1. The first implementation injected the Telegram bot token via
   Alertmanager's supposed `--config.expand-env` flag. Real deploy
   against the live cluster crash-looped immediately:
   `"unknown long flag '--config.expand-env'"`. That flag never existed
   for Alertmanager — confirmed directly via the container's own
   `--help` output before writing a fix, not by re-reading
   documentation harder. Fixed with the actual supported mechanism:
   `telegram_configs`' native `bot_token_file`/`chat_id_file` fields,
   reading from the same SealedSecret mounted as files — verified
   against a throwaway pod (checked for schema-parse errors) before
   trusting it a second time.
2. The real-trigger test — deliberately breaking a disposable pod and
   confirming the alert actually fires and a message actually arrives,
   not just checking rule syntax — caught a second, unplanned bug: the
   `PodNotReady` rule fired on a real pod, `jenkins/helm-debug`, a
   `Completed` one-shot debug pod from days earlier that will never be
   `Ready` again *by design*. A textbook alert-fatigue false positive,
   caught before it shipped rather than a week into production nagging.
   Fixed by restricting the rule to pods actually in the `Running`
   phase.

**The real-trigger test itself is the strongest answer here, if asked
"how do you know your alerting actually works":** not "the YAML is
valid" — a real pod was deliberately broken, watched through its actual
lifecycle to `CrashLoopBackOff`, through Prometheus's scrape picking up
the metric, through the alert going `pending` then `firing` after its
real `for` window, through Alertmanager dispatching it
(`alertmanager_notifications_total` incremented, zero failures), to
**igalhub confirming the literal Telegram message arrived** on his
phone, pasted back with matching labels. The `PodNotReady` false
positive delivered for real too, before its fix — a second, unplanned
but equally genuine proof the whole pipeline works end to end, not just
the one deliberately staged test.

**Why this is worth telling over a cleaner-sounding success story:**
both bugs were found by actually deploying and actually triggering a
failure, not by careful reading in advance — and both were caught and
fixed *before* shipping, which is the entire point of doing the
real-trigger verification instead of stopping at "the config looks
right."

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
- **No full production DR for the databases** — PX-020 shipped a real,
  tested backup/restore story (WAL-G continuous archiving + daily base
  backups to in-cluster MinIO, verified via an actual checksum-matched
  restore), so this is narrower than it used to be: what's still missing
  is DR in the "another site/another cluster" sense — the backup target
  itself lives in the same cluster as the data it protects, so a
  whole-cluster or whole-host loss takes out both together.

---

## Where things stand right now

Steps 1 through 10 are done: cluster provisioned and running, core
services (ingress/Redis/Postgres/Sealed Secrets), observability
(Prometheus/Grafana in-cluster), Jenkins with a real,
SCM-poll-verified pipeline, and the landing page — built, deployed via
its own Jenkins-driven kaniko build/push, and proven live against real
cluster data. **Step 11 (ArgoCD, PX-015) is done**: ArgoCD is installed
and all 10 existing releases (landing page, kube-state-metrics,
node-exporter, Prometheus, Grafana, Jenkins, Postgres operator, Sealed
Secrets, Redis, nginx-ingress) are adopted under GitOps, each verified
without disrupting the running workload. **Step 12 (PX-020/021/022) is
done**: Postgres has a real, tested WAL-G backup/restore story; ingress
reaches the cluster via a real dedicated LoadBalancer IP (MetalLB) instead
of a NodePort; Postgres and Redis both run on Longhorn (distributed,
replicated storage) instead of `local-path`. **Step 13 (PX-023) is
done**: the Proxmox memory-gauge issue is fully resolved (ballooning
enabled via Terraform), closing out a three-ticket root-cause chain
that started back at PX-007. **Step 14 (PX-025) is done**: Alertmanager
+ Telegram alerting is live, verified via a real triggered failure that
a human confirmed actually reached his phone. **Step 15 (PX-026) is
done**: Redis, Postgres, Longhorn, and MinIO all export real Prometheus
metrics now, each via a mechanism confirmed against the live
chart/CRD rather than assumed — giving a future "project services"
dashboard something real to query (PX-027 fixed a related cosmetic gap
in the same area: node-exporter's dashboard was filtering on raw IPs
instead of hostnames). Live status: `docs/TICKETS.md`.

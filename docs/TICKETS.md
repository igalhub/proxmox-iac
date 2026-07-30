# TICKETS — proxmox-iac

One branch + one PR per ticket. No bundling unrelated changes. CI green
before merge. Shellcheck before merging any bash.

---

## PX-001 — Repo scaffold

**Status:** DONE

**Description:**
`README.md`, `CLAUDE.md`, `docs/PRD.md`, `docs/SPEC.md`, `docs/TICKETS.md`,
`.gitignore`, `HANDOFF.md`.

**Acceptance criteria:**
- [x] Standard doc structure in place
- [x] `docs/SPEC.md` covers full architecture with every tool choice explained
- [x] `HANDOFF.md` scaffolded (gitignored, four-field format)

---

## PX-002 — CI + lint tooling

**Status:** DONE

**Description:**
`.github/workflows/ci.yml` (shellcheck now; Terraform fmt/validate and
ansible-lint jobs guarded to skip until `terraform/`/`ansible/` exist, so
they activate automatically once those phases land instead of needing a
CI edit each time). `Makefile` (`lint`, `test`, `install-hooks`,
`check-hooks`). `hooks/pre-commit` — plain git hook (shellcheck on staged
`.sh` files), installed via `make install-hooks` since this isn't a
Python project (no `pre-commit` framework to hang it on).

**Acceptance criteria:**
- [x] CI runs shellcheck on every push/PR
- [x] CI's Terraform/Ansible jobs no-op cleanly until those dirs exist
- [x] `make install-hooks` installs a working pre-commit shellcheck hook

---

## PX-003 — Cloud-init Ubuntu 24.04 template on Proxmox

**Status:** DONE

**Description:**
`scripts/build-cloud-init-template.sh` — downloads the Ubuntu 24.04 cloud
image, `qm create`/`qm importdisk`/`qm set` (cloud-init drive, boot order,
serial console, guest agent), `qm resize`, `qm template`. Deliberately
does not set `ciuser`/`sshkey` on the template — per-VM identity is
Terraform's job at clone time.

**Correction (2026-07-30):** this script was written in an earlier Cowork
session but only ever saved to that session's scratch/output folder, not
committed to the repo — `scripts/` didn't exist in git history at all.
Status had been carried forward across sessions/docs as "delivered" without
anyone verifying it against actual repo state. Caught when a later
Claude Code session tried to run it for real and found nothing there.
Now actually committed. Lesson: a file only "exists" once it's in the
repo — a chat/session artifact isn't the same thing, and status claims in
TICKETS.md/HANDOFF.md need to be re-verified against `git log`/`ls`, not
carried forward from a prior session's say-so.

**Acceptance criteria:**
- [x] Script actually committed to `scripts/build-cloud-init-template.sh`
- [x] Igal confirms SSH access to `192.168.10.50` — `homelab` alias
      repointed from the destroyed `.6` VM to `.50`, `User root`, ed25519
      key (`~/.ssh/homelab`) appended to `/root/.ssh/authorized_keys` via
      the Proxmox web UI's node Shell. `ssh homelab` now authenticates
      without a password prompt.
- [x] `free -h` / `qm list` / `pvesm status` / `ip a` run on the real host
      (2026-07-30): 27Gi RAM total, 25Gi free, zero existing VMs;
      `local-lvm` active with ~793GiB free; `vmbr0` up, carries
      `192.168.10.50/24`. Script's defaults (`local-lvm`, `vmbr0`, VMID
      `9000`) all confirmed correct, no changes needed.
- [x] Igal has run the script on `192.168.10.50`
- [x] Template VMID 9000 confirmed present and marked as a template —
      verified via `qm config 9000` output showing `template: 1` and the
      disk renamed to `base-9000-disk-0` (Proxmox's own signal that a VM
      was actually converted, not just left as a regular VM)

---

## PX-004 — Terraform module skeleton

**Status:** DONE

**Description:**
`terraform/` with `providers.tf` (bpg/proxmox), `variables.tf`,
`outputs.tf`. No VM resources yet — just the module wired up and
authenticating against the Proxmox API.

**Proxmox-side setup (2026-07-30):** dedicated `terraform@pve` user, custom
`Terraform` role scoped to clone/configure privileges only (`Sys.Audit`,
`Datastore.Audit`, `Datastore.AllocateSpace`, `VM.Audit`, `VM.Allocate`,
`VM.Clone`, `VM.Config.CPU/Memory/Disk/Network/Cloudinit/Options/CDROM`,
`VM.PowerMgmt`, `VM.GuestAgent.Unrestricted`) bound at path `/`, API token
`terraform-iac` (Privilege Separation off).

**Correction (PX-005 first apply attempt):** this list was incomplete —
`SDN.Use` is also required to attach a VM's network device to `vmbr0`,
even though it's a plain Linux bridge with no actual SDN configuration.
Proxmox 9.x apparently wraps every bridge under an implicit SDN
"localnetwork" zone internally, and permission checks go through that
zone regardless. Found via a real `HTTP 403` on `terraform apply`, not
anticipated in advance — added to the `Terraform` role after the fact.
Worth remembering for the interview story: the original reasoning for
omitting it (only matters for actual SDN-managed networks) was sound
logic that turned out to be wrong for this specific Proxmox version —
exactly why QA verifies against the real host instead of trusting
reasoning alone.

**Second correction (same retry cycle):** `VM.Config.HWType` also
required — a real Proxmox privilege (distinct from `VM.Config.CPU`
and `VM.Config.Options`) covering OS type/machine type/BIOS-level
settings, which the clone sets from the template's `ostype: l26`.
Added to the `Terraform` role. Pattern holding so far: each missing
privilege surfaces as its own individual `403` on the specific field
it gates, one at a time, rather than Proxmox reporting everything
missing up front — expect this list to still be provisional until a
`terraform apply` actually completes end to end.

**Partial-state note, worth remembering as a Terraform concept, not just
a Proxmox one:** this failure happened *after* the clone step succeeded
but before full configuration (resize/CPU/memory/cloud-init) applied —
confirmed via `terraform state list` (all 3 resources tracked) and `qm
list` on the host (VMs 110/111/112 exist, still at the template's
original sizing). Checked before advising any fix, per the "verify no
partial state" habit. Because Terraform's state already tracks these as
existing resources, the next `apply` performs an in-place update to
finish configuring them — it does not re-clone or duplicate. This is
Terraform's state model doing exactly what it's supposed to: a failed
apply mid-way through doesn't mean starting over, it means resuming from
wherever reality actually got to.

`VM.Monitor` — present in
bpg/proxmox's example role — confirmed **absent entirely** from PVE 9.2's
role privilege list (not renamed, not findable under any filter), matching
the provider docs' own warning that available privileges changed in PVE
9.0. Omitted; not required for a clone/configure-only workflow (it gates
QEMU monitor/console access). Revisit only if a later phase needs console
access.

**Acceptance criteria:**
- [x] `terraform init` succeeds (bpg/proxmox v0.111.1 installed cleanly)
- [x] `terraform plan` runs cleanly against the real Proxmox host with zero
      resources defined yet (proves API auth works before adding VMs) —
      QA-verified 2026-07-30: `terraform plan` against `192.168.10.50`
      returned "No changes. Your infrastructure matches the
      configuration." with the real `terraform@pve!terraform-iac` token

---

## PX-005 — Terraform VM resource definitions

**Status:** DONE

**Final verification (2026-07-30):** after the `SDN.Use` and
`VM.Config.HWType` corrections, `terraform apply` completed clean —
Terraform's in-place update finished configuring the 3 already-cloned VMs
(resize/CPU/memory/cloud-init) rather than re-cloning, per the partial-state
note above. Verified independently, not from Terraform's own exit code
alone: direct `ssh -i ~/.ssh/homelab ubuntu@192.168.10.1{0,1,2}` to all
three VMs succeeded — real SSH auth via the cloud-init-injected key,
not console access — and `ip a` on each shows the exact static address
Terraform declared (`.10`/`.11`/`.12` on `eth0/24`), matching
`docs/SPEC.md` §4 precisely. This is the strongest available proof: it
confirms cloud-init actually ran, the network config actually applied,
and the SSH path Ansible will reuse in PX-007 already works end to end.

Separately cross-checked sizing against the Proxmox UI's own resource
view for all 3 VMs — cp-1: 2 CPU/4.00GiB/40.00GiB, wk-1 and wk-2: both
3 CPU/8.00GiB/60.00GiB, all "running." Matches `docs/SPEC.md` §3 exactly.
Sizing and networking are now each confirmed via two independent sources
(Proxmox's own view vs. what's observable from inside the guest OS),
not just Terraform's own reported success.

**Description:**
VM resources for cp-1/wk-1/wk-2, cloned from the PX-003 template, with
per-VM cloud-init config (hostname, static IP, SSH key) and sizing per
`docs/SPEC.md` §3 resource budget.

**Implementation notes (2026-07-30):** `terraform/vms.tf` — one
`proxmox_virtual_environment_vm` resource with `for_each` over a
`locals.nodes` map (cp-1/wk-1/wk-2 differ only in vm_id/IP/sizing, so
generated rather than copy-pasted). VMID scheme mirrors the static IP's
last octet (110/111/112 ↔ .10/.11/.12) for easy correlation. `vga`/
`serial_device` blocks explicitly pinned to match the PX-003 template's
headless serial-console config (`vga: serial0` / `serial0: socket` in
`qm config 9000`), since the provider's own default (`vga.type = "std"`)
would otherwise silently drift it. Full clone (`clone.full = true`), not
linked — simpler failure mode for a lab, no shared dependency on the
template disk surviving. Node name (`pve`) confirmed live via
`pvesh get /nodes`, not assumed.

`terraform plan` against the real host: 3 to add, 0 to change, 0 to
destroy — sizing/IPs/VMIDs all match SPEC.md exactly.

Router DHCP/static-lease spot-check (docs/SPEC.md §4) is now fully
resolved — pool narrowed to `192.168.10.21`–`.49`, structurally excluding
both `.10`–`.12` and `.50` from anything DHCP can hand out. No longer a
blocker.

**First `terraform apply` attempt (2026-07-30): failed on all 3 VMs.**
`HTTP 403, Permission check failed (/sdn/zones/localnetwork/vmbr0,
SDN.Use)`. Proxmox 9.x wraps even a plain Linux bridge under an implicit
SDN "localnetwork" zone; attaching a VM's NIC to it requires `SDN.Use`,
which had been deliberately omitted during PX-004's role setup on the
assumption (wrong, for this PVE version) that it only mattered for
actually-SDN-managed networks. Verified no partial/orphaned state before
fixing anything: `terraform state list` empty, `qm list` on the host
showed only the template — clone failed before creating anything, nothing
to clean up. Fix: added `SDN.Use` to the `Terraform` role (PX-004's
privilege list above needs a follow-up correction once this is fully
verified). Token inherited it immediately (Privilege Separation off, no
regeneration needed). Retry pending.

**Acceptance criteria:**
- [x] `terraform apply` produces 3 VMs matching the SPEC.md sizing table
      — succeeded after the `SDN.Use`/`VM.Config.HWType` role corrections
- [x] All 3 VMs are SSH-reachable at their planned static IPs with no
      manual intervention after `apply` — verified via real SSH + `ip a`
      on all three (see final verification note above)

---

## PX-006 — Terraform state decision

**Status:** DONE

**Description:**
Decide and document (in `docs/SPEC.md`) local state file vs. a
self-managed remote backend. Home-lab single-operator project, so local
state may be the pragmatic answer — but the trade-off (no state locking,
no backup) needs to be a stated decision, not a default.

**Decision (2026-07-30):** local state, documented in `docs/SPEC.md` §9
with full rationale. Local state was already the de facto choice from
PX-004/PX-005 (nothing else was ever configured) — this ticket makes it
an explicit, defensible decision rather than an unexamined default.
Trade-off named precisely: local backend does lock against concurrent
applies from the *same* machine (confirmed via the real
`.terraform.tfstate.lock.info` observed during PX-005's apply), so the
actual gap is "no locking/durability across machines," narrower than
"no locking at all." Revisit trigger stated: a second operator or CI
running `apply` directly (not just `validate`/`plan`).

**Acceptance criteria:**
- [x] Decision recorded in `docs/SPEC.md` with rationale (§9)
- [x] `.gitignore` exclusion of `*.tfstate*` verified actually honored —
      `git check-ignore -v` against the real state files created during
      PX-005's apply, and `git log --all -- terraform/terraform.tfstate`
      confirms neither file has ever appeared in git history

---

## PX-007 — Ansible inventory + roles skeleton

**Status:** DONE

**Description:**
`ansible/inventory` (static, matching Terraform outputs), `ansible.cfg`,
role skeletons: common/hardening, k3s-server, k3s-agent. Resolve whether
a separate containerd role is needed or if k3s's embedded containerd
makes that redundant (see SPEC.md build order note) before writing it.

**Containerd resolution:** no separate role — k3s bundles and manages
its own embedded containerd, per `docs/SPEC.md`. A dedicated role would
just duplicate what `k3s-server`/`k3s-agent` already own in PX-008.

**Implementation notes (2026-07-30):** `common` role is real, functional
content (not an empty stub) — apt baseline, non-root `deploy` user
creation, passwordless sudo, SSH key install, and SSH hardening
(disable password auth + root login). `k3s-server`/`k3s-agent` are
deliberate placeholder stubs (`ansible.builtin.debug` only) — their real
install/join logic is explicitly PX-008's job, not this ticket's.

**Deliberately NOT run for real yet:** this ticket's acceptance criteria
only require `--check` (dry-run) to pass, not an actual apply. Hardening
tasks touch `sshd_config` (disable password auth / root login) — a real
run belongs alongside PX-008's actual k3s bring-up, gated behind
explicit confirmation the same way `terraform apply` was, since a
mistake here risks the SSH access every later step depends on. Verified
after the `--check` run that nothing was actually applied: `id deploy`
returns "no such user" on all 3 real hosts.

**Real check-mode bug caught and fixed:** `ansible.posix.authorized_key`
failed in check mode with "Either user must exist or you must provide
full path to key file in check mode" — the module needs to resolve the
deploy user's home directory via the OS user database, which doesn't
exist yet in a dry run (the preceding user-creation task is only
simulated, not applied). Fixed by giving the task an explicit `path`
instead of relying on user lookup.

**Acceptance criteria:**
- [x] `ansible-lint` passes on all roles — clean at the `production`
      profile (15 files), after fixing real violations: var-naming
      (`common_` prefix), missing `meta.galaxy_info.author`, task/play
      name casing, and an invalid `platforms.versions` value
- [x] `ansible-playbook --check` runs without errors against the 3 real
      VMs — `failed=0`, `unreachable=0` across cp-1/wk-1/wk-2, confirmed
      via a real run against `192.168.10.10-12`, not assumed

---

## PX-008 — k3s cluster bring-up

**Status:** DONE

**Description:**
k3s-server role installs on cp-1 with `--disable=traefik`, captures join
token; k3s-agent role installs on wk-1/wk-2 and joins using that token.

**Implementation notes (2026-07-30):** `k3s-server` uses the official
`get.k3s.io` install script with `INSTALL_K3S_EXEC=server
--disable=traefik --write-kubeconfig-mode=644`, waits for the real
node-token file, reads and `set_fact`s it, then fetches the kubeconfig
locally (`.kubeconfig`, gitignored — real cluster admin credential,
never committed) and patches its server address from `127.0.0.1` to the
control-plane's real IP. `k3s-agent` reads the token via `hostvars` from
the control-plane host (facts persist across plays within one
`ansible-playbook` run — `k3s-server` always runs before `k3s-agent` in
`site.yml`'s play order) and joins with `INSTALL_K3S_EXEC=agent`.

**Why `--check` can't fully verify this ticket, unlike PX-007's `common`
role:** the task chain has a genuine, inherent dependency on real side
effects — `slurp`ing the node-token file requires the file to actually
exist, which only happens after a real (non-simulated) install runs.
Confirmed by actually running `--check`: it correctly got through the
install-script tasks (simulated as `changed`), then failed for real at
`slurp` with "File not found" — not a bug, the expected shape of this
limitation. `ansible-playbook --syntax-check` (validates YAML/module
resolution, no host connection needed) is the correct pre-flight bar
here instead, and passes clean. This is exactly the "some things
genuinely can't be verified outside the real environment" case, not a
gap to paper over.

**Real run (2026-07-30):** before running for real, re-confirmed task
order directly from the actual `common` role file (not from memory) —
deploy-user creation (line 14) and SSH key install (line 29) both come
before the two hardening tasks (lines 41/48), and both hardening tasks
only `notify` a handler, which runs once at the end of the play, after
the deploy user and its key are already fully in place. `ansible-playbook
site.yml` (no `--check`) then ran clean end to end against all 3 real
VMs: `failed=0`, `unreachable=0` on cp-1/wk-1/wk-2 (`ok=18/12/12`,
`changed=11/9/9`). Nothing unexpected during the run itself.

**Verified independently after the run, not from Ansible's own exit
code:**
1. Real SSH key-based login as the new `deploy` user succeeded on all 3
   hosts, and passwordless `sudo` worked (`sudo -n whoami` → `root`).
2. The original `ubuntu` user was **left alone, not removed** — its
   key-based access still works on all 3 hosts. (Disabling password auth
   doesn't affect any user's key-based login; the role never touched the
   `ubuntu` account itself, only added `deploy` alongside it.)
3. `kubectl get nodes -o wide` from cp-1 (as `deploy`, via `sudo`) shows
   all 3 nodes **Ready**: cp-1 (control-plane), wk-1, wk-2 — k3s
   `v1.36.2+k3s1`, `containerd://2.3.2-k3s2`.
4. Password auth and root login are genuinely refused, checked two ways,
   not just trusted from the task's "changed" report: (a) a live SSH
   attempt with `PreferredAuthentications=password` against `ubuntu@`
   shows the server's own auth banner offering only `publickey` — password
   isn't even a method the server offers, not just a client-side failure;
   (b) `sshd -T` (the daemon's live, authoritative effective config, not
   the static file) confirms `passwordauthentication no` and
   `permitrootlogin no` on all 3 hosts directly.

**Correction (2026-07-31, found during PX-010):** `docs/SPEC.md` §1
claims cp-1 is "tainted `node-role.kubernetes.io/control-plane:NoSchedule`,
the k3s default" — that's wrong. k3s does **not** apply this taint by
default; it only exists if `--node-taint` is explicitly passed at
install time, and this role's `INSTALL_K3S_EXEC` never included it. The
gap was invisible until PX-010, because everything scheduled so far
(PX-009's core services) was already explicitly pinned to `wk-1`/`wk-2`
via `nodeSelector` — nothing had actually tried to land on cp-1 to
expose the missing enforcement. Caught by checking `kubectl describe
node cp-1` for real instead of trusting the SPEC's claim.

Two fixes applied, not one — a live `kubectl taint` alone would have
silently disappeared on any future rebuild of cp-1 (VM destroyed and
recreated, k3s reinstalled fresh), reproducing the exact same
undocumented-drift problem:
1. **Immediate/live:** `kubectl taint nodes cp-1
   node-role.kubernetes.io/control-plane=true:NoSchedule` — reversible,
   applied directly against the running cluster.
2. **Root cause:** `ansible/roles/k3s-server/tasks/main.yml`'s
   `INSTALL_K3S_EXEC` now includes `--node-taint
   node-role.kubernetes.io/control-plane=true:NoSchedule`, so a future
   rebuild applies it automatically at install time — the drift can't
   recur silently.

Verified, not assumed: re-ran `ansible-playbook site.yml --limit cp-1`
after the role change — `failed=0`, and the install task itself reports
`ok` (not `changed`), correctly skipped via its `creates:` guard since
k3s is already installed on this VM. `kubectl describe node cp-1`
confirms exactly one taint, unchanged, no duplicate/conflicting taint
introduced by the idempotent re-run. `k8s/node-exporter/values.yaml`
(PX-010) given an explicit toleration for this taint rather than
relying implicitly on the chart's generic "tolerate any NoSchedule"
default — node-exporter is supposed to run everywhere, including the
control-plane; only app workloads should be kept off it, and that
distinction is now visible in the values file, not just inherited.

**Acceptance criteria:**
- [x] `ansible-lint` passes on the updated roles at the `production`
      profile
- [x] `ansible-playbook --syntax-check` passes clean
- [x] `kubectl get nodes` (run from cp-1 or with kubeconfig pulled locally)
      shows 3 Ready nodes — verified directly via SSH as the new `deploy`
      user, not assumed from Ansible's report
- [x] End-to-end: clean `terraform apply` + `ansible-playbook` run produces
      a working cluster with zero manual steps — both phases (PX-005's
      apply, this ticket's real playbook run) completed clean end to end

---

## PX-009 — Core services (ingress, Redis, Postgres, Sealed Secrets)

**Status:** DONE

**Description:**
nginx-ingress via Helm (Traefik confirmed disabled), Redis via Bitnami
Helm chart, Zalando Postgres Operator + one provisioned `postgresql` CR,
Sealed Secrets controller with at least one real secret sealed and
committed instead of left in plaintext values files.

**Implementation notes (2026-07-30):** installed via plain `helm
install`/`kubectl apply` against the live cluster — ArgoCD retrofit is
build-order step 8, after core services are stable, so this
deliberately isn't GitOps yet. Full install commands and rationale in
`k8s/README.md`. Deviated from the ticket's listed component order:
installed Sealed Secrets *before* Redis so Redis's own auth password
could be a real sealed secret from the start, instead of a plaintext
values-file password later rotated — one coherent implementation, no
circling back.

Sealed-secrets Helm repo had moved from `bitnami-labs.github.io` to
`bitnami.github.io` (June 2026) — the ticket's/docs' assumed old URL
404'd; caught and used the correct current one. `kubeseal` CLI installed
locally matching the controller's exact version (`0.38.4`).

Postgres CR uses `numberOfInstances: 1`, not the 2-node example from
`docs/SPEC.md`'s operator rationale — deliberate trade-off against the
resource budget (§3), not a limitation of the pattern; scaling to HA is
a one-line CR change. Full reasoning in `k8s/README.md`.

**Verified for real, not from Helm's own `--wait`/exit code:**
- nginx-ingress: deployed a throwaway test app (`k8s/test-app/hello.yaml`,
  deleted after), routed a real `curl` through the actual NodePort →
  ingress → Service → pod path, got HTTP 200.
- Redis: generated a real password, sealed it, applied the `SealedSecret`,
  confirmed it decrypted into a real `Secret` in-cluster. Spun up a test
  pod, connected with the real password, got `PONG` and a real `SET`/`GET`
  round-trip.
- Postgres: confirmed the operator auto-generated real credential Secrets
  (`app-user.proxmox-iac-pg.credentials...`), connected from a test pod
  using them, ran a real `SELECT 1, version()` against `app_db` as
  `app_user` — PostgreSQL 18.3 confirmed live.
- Confirmed no plaintext secret material anywhere in the committed YAML
  (`grep` across `k8s/` before committing) — only the encrypted
  `SealedSecret` blob and field-name references.
- All pods `Running` (`kubectl get pods -A | grep -v Running` empty),
  nginx-ingress/Redis/Postgres all correctly landed on `wk-1` per the
  SPEC role split.

**Acceptance criteria:**
- [x] Test route through nginx-ingress works — real HTTP 200 via `curl`
      through the actual NodePort/ingress/Service/pod path
- [x] Redis reachable from a test pod — real `PONG` + `SET`/`GET`
      round-trip using the sealed password
- [x] Postgres CR provisions successfully, connection verified — real
      `SELECT` query against `app_db` using operator-generated credentials
- [x] At least one `SealedSecret` committed and decrypting correctly
      in-cluster — `k8s/redis/redis-auth-sealedsecret.yaml`, confirmed
      decrypted into a real `Secret` before Redis ever used it

---

## PX-010 — Observability (in-cluster Prometheus + Grafana)

**Status:** DONE

**Scope correction (2026-07-30):** originally planned to extend an
existing home-lab Prometheus/Grafana instance. During PM review, that
instance turned out not to exist anymore — it was running on the old
`192.168.10.6` Ubuntu VM (NodePort `30093`, so it was itself an in-cluster
Grafana on whatever was running there) that got wiped at this project's
start. Confirmed with Igal via explicit decision rather than assumed:
deploy fresh Prometheus + Grafana in-cluster via Helm instead of leaving
monitoring unresolved. `docs/PRD.md` and `docs/SPEC.md` §§1-2 updated to
match — this is no longer "extend existing," it's "provision monitoring
as code," which is arguably a better fit for this project's own premise
anyway.

**Description:**
kube-state-metrics + node-exporter deployed to the new cluster (as
originally planned); Prometheus + Grafana deployed fresh via Helm on
wk-1 (grouped with the other always-on services, kept off wk-2 to avoid
contending with Jenkins builds — see `docs/SPEC.md` §1); Grafana
dashboard added showing the new cluster's node/pod health.

**Sizing note:** remaining host-level headroom is tight (~5GB, per
`docs/SPEC.md` §3) and that number is about host RAM, not what's free
*inside* wk-1's 8GB once Postgres/Redis/ArgoCD/ingress/landing page are
already running there. Check actual free memory inside wk-1 before
choosing between a full `kube-prometheus-stack` (bundles Alertmanager +
extra exporters, likely more than needed) vs. slimmer standalone
Prometheus + Grafana charts — don't assume either fits, verify.

**Implementation notes (2026-07-31):** kube-state-metrics pinned `wk-2`
(grouped with Jenkins, per SPEC role split); node-exporter DaemonSet
across all 3 nodes with an explicit toleration for the control-plane
taint (see PX-008 correction above — that taint didn't actually exist
until this ticket surfaced the gap). Standalone `prometheus`/`grafana`
charts, not `kube-prometheus-stack` — the standalone `prometheus` chart
bundles kube-state-metrics/node-exporter as subcharts by default,
disabled to avoid duplicating the separately-placed releases;
Alertmanager and pushgateway also disabled. Grafana's admin password is
a real sealed secret (`k8s/grafana/grafana-admin-sealedsecret.yaml`),
same pattern as PX-009's Redis password. Two community dashboards
provisioned via `gnetId`: Node Exporter Full (1860) + Kubernetes cluster
monitoring via Prometheus (315), covering node and pod health
respectively. Full commands/rationale in `k8s/README.md`.

**Verified for real, not from Helm's `--wait`/exit code:**
- Prometheus targets: queried its real `/api/v1/targets` — all 3
  `kubernetes-nodes`/`kubernetes-nodes-cadvisor` targets `up`, both
  node-exporter and kube-state-metrics `kubernetes-service-endpoints`
  targets `up`.
- Grafana reachable via the actual ingress path: `curl` with a
  `Host: grafana.lab.test` header through the real NodePort →
  `/api/health` returns `"database": "ok"`.
- Both dashboards genuinely imported: queried `/api/search?type=dash-db`
  through the same ingress path, confirmed both titles present.
- Data actually flows end to end, not just "installed": queried
  Grafana's own datasource proxy (`/api/datasources/proxy/uid/.../query`)
  for `up` — real live results for all 3 nodes across
  `kubernetes-nodes`/`cadvisor`/node-exporter/kube-state-metrics jobs,
  every one reporting `1`.
- Memory footprint checked post-deploy per the sizing note, not
  skipped: `free -h` on wk-1 before this ticket showed 7.0Gi available;
  after Prometheus + Grafana + node-exporter, 6.6Gi available — a
  comfortable, confirmed fit, not assumed.

**Acceptance criteria:**
- [x] In-cluster Prometheus deployed via Helm, scraping kube-state-metrics
      + node-exporter directly (no external scrape-config needed now)
- [x] In-cluster Grafana deployed via Helm, reachable via nginx-ingress
- [x] Grafana dashboard renders live node/pod health data for all 3 nodes
- [x] Actual memory footprint on wk-1 checked post-deploy against the
      sizing note above, documented in this ticket either way

---

## PX-011 — Reconcile scaffold against real `igalhub/project-template`

**Status:** DONE — `.claude/dev-check.sh` copied in and verified via a real `/dev-check` run (terraform/kubectl/helm UP, proxmox-host UP; ansible DOWN and k3s-cluster DOWN both expected at this stage)

**Description:**
Original scaffold (PX-001) was hand-built from documented conventions
because the real template wasn't reachable in that session (private
repo, no GitHub connector authorized). Once Igal pointed at the local
path (`~/claudecode/projects/project-template`), diffed against it and
reconciled: `CLAUDE.md` rewritten to match the real PM/Developer/QA
workflow (explicit role statements, commit convention, branch naming),
`TICKETS.md` reformatted to the real PX-NNN/Status/Acceptance-criteria
convention, CI + Makefile + `hooks/pre-commit` added following the
template's `--lang bash` shape (this repo is Terraform/Ansible, not
Python, so the bash path is the closer match, extended with
Terraform/Ansible-aware CI jobs the template itself has no opinion on).

**Acceptance criteria:**
- [x] `CLAUDE.md` matches the real template's workflow rigor
- [x] `TICKETS.md` matches the real template's ticket format
- [x] CI/Makefile/hooks added per the bash-path pattern
- [x] `.claude/dev-check.sh` — copied in manually (write was blocked in
      the Cowork session that authored it), verified working via a real
      `/dev-check` run

---

## PX-012 — Interview walkthrough doc

**Status:** DONE

**Description:**
`docs/INTERVIEW_WALKTHROUGH.md` — a step-by-step, interview-rehearsal
narrative of the full build plan (why each tool was chosen, in what
order, what "done" means at each step), distilled from `docs/PRD.md` and
`docs/SPEC.md`. Study aid, not a spec — `SPEC.md` remains the
authoritative architecture doc; this restates it in defend-under-
questioning form.

**Acceptance criteria:**
- [x] Covers every build-order step (PX-003 through the ArgoCD retrofit)
      with a "why this, not X" answer for each major tool choice
- [x] Covers the documented non-goals (no HA control-plane, no Vault,
      single Proxmox host, no DB DR)
- [x] Ends with an accurate "where things stand right now" section

---

## PX-013 — Jenkins CI (Helm) with a real pipeline

**Status:** OPEN

**Description:**
Jenkins deployed via its official Helm chart on `wk-2` — grouped with
kube-state-metrics/node-exporter per `docs/SPEC.md`'s role split,
isolated from `wk-1`'s always-on data services (Postgres/Redis/ingress).
Given real work per `docs/PRD.md`: a `Jenkinsfile` pipeline that runs
`terraform validate`, `ansible-lint`, and a Helm chart lint on every
push to this repo — not a decorative idle pod.

**Resource sizing (2026-08-01):** confirmed live via `free -h` on `wk-2`
before sizing anything, not assumed — **7.1Gi available** (of 7.8Gi
total), only ~689Mi currently used by kube-state-metrics + node-exporter
combined. `docs/SPEC.md` has called Jenkins "the heaviest single
component" since the original spec was written, and PX-010 already
showed the project's remaining RAM headroom is tighter than the
original planning numbers assumed — so sized modestly here anyway,
rather than leaning on the comfortable headroom: this pipeline's actual
workload is lint/validate, not compilation or a heavy build. Controller:
requests `512Mi`/`250m`, limit `1Gi`/`500m`. Dynamic agent pod template:
requests `256Mi`/`100m`, limit `512Mi`/`250m`.

**Build-agent strategy — decided, not left open** (`docs/SPEC.md` §8
previously listed this as unresolved): **dynamic Kubernetes pod agents**
via the Jenkins Kubernetes plugin, not a static agent. Rationale:
matches this project's "provisioned as code" ethos (no manually
maintained agent to patch or keep running), scales to zero between
builds (no baseline RAM cost sitting idle against the tight remaining
budget), and is the pattern most real orgs actually use for
Kubernetes-hosted Jenkins today. Agent pod template pinned to `wk-2` via
`nodeSelector`, same as the controller.

**Pipeline trigger mechanism — decided:** SCM polling (`pollSCM`), not a
GitHub webhook. This cluster has no public ingress exposed to GitHub
(nginx-ingress is only reachable inside the home LAN) — GitHub can't
deliver a webhook here without a reverse tunnel/public endpoint, which
is out of scope for this ticket. Polling is slower than a webhook, but
it's a real, working trigger against a real push, which is what the
acceptance criteria below actually require — not a simulated or
manually-triggered run standing in for one.

**Implementation notes (2026-07-31):** Jenkins deployed via Helm on
`wk-2`. First install attempt's `--wait --timeout 5m` was too short —
the chart's `init` container downloads `workflow-aggregator`'s full
transitive plugin tree, genuinely still progressing past 5 minutes, not
hung (confirmed by tailing its logs). Waited properly via `kubectl wait`
instead, then `helm upgrade` to reconcile the release status back to
`deployed` (the timed-out `helm install` had marked it `failed` without
rolling anything back, since `--atomic` wasn't set).

Repo is private, so the pipeline needs real Git credentials to clone
it — not skipped. Generated a dedicated read-only SSH deploy key,
added to GitHub via `gh api repos/.../keys`, sealed as a
`kubernetes.io/ssh-auth`-shaped Secret
(`k8s/jenkins/jenkins-github-deploy-key-sealedsecret.yaml`) matching the
`kubernetes-credentials-provider` plugin's exact expected schema
(labels/annotations, `username`/`privateKey` fields) — added that
plugin plus `rbac.readSecrets: true` to `k8s/jenkins/values.yaml` so the
sealed key surfaces as a real Jenkins credential without ever entering
Jenkins' own credential store as plaintext. Verified via the real
credentials API: credential ID `jenkins-github-deploy-key`, correctly
typed "SSH Username with private key", username `git`.

`scripts/helm-lint-values.sh` written and run locally for real before
trusting it in the pipeline — pulls each `k8s/*/values.yaml`'s real
upstream chart fresh (since these are values files for remote charts,
not local chart directories `helm lint` can target directly) and lints
against it. All 9 current charts pass. Shellchecked clean.

Caught and fixed a real bug in the `Jenkinsfile` before it ever ran:
`pip install ansible.posix` — not a pip package, it's a Galaxy
collection, already handled by the `ansible-galaxy collection install`
line right after. `terraform validate` confirmed to need no real
Proxmox credentials (validates syntax/schema, not live infra), matching
this project's decision to keep apply-capable credentials out of CI.

**Real run, job creation, and two more real bugs found (2026-07-31):**
Job created via the Jenkins REST API (`createItem`), "Pipeline script
from SCM" pointing at `git@github.com:igalhub/proxmox-iac.git`,
`master`, credential `jenkins-github-deploy-key`.

*Bug 1 — SSH host key verification.* First build failed at checkout:
`No ED25519 host key is known for github.com and you have requested
strict checking.` Fixed live by appending GitHub's real, published host
keys (from `https://api.github.com/meta`) to the controller's
`known_hosts`. Second build still failed — the *dynamic agent pod*
(a fresh, ephemeral container per build) has no persistent filesystem
and no `known_hosts` of its own, so the controller-only fix didn't
cover it. Fixed properly via Jenkins' global "Git Host Key Verification
Configuration" (`org.jenkinsci.plugins.gitclient.GitHostKeyVerificationConfiguration`,
`ManuallyProvidedKeyVerificationStrategy`, set via the Script Console —
first attempt used the wrong package path and failed to compile;
corrected after a web search confirmed the real one), which the
git-client plugin consults everywhere, not just per-filesystem. This
covers every future agent pod, not just the one that happened to fail.

*Bug 2 — a genuinely missing file, not a flaky test.* Build #3 (first
full green run) reported "SUCCESS" but its Helm Chart Lint stage only
linted 8 of 9 charts — `sealed-secrets` silently absent, no error. The
script's `[ -f "$values_file" ] || continue` swallowed a missing file
with zero logging. Could not reproduce locally (9/9, twice) or via
`kubectl exec`/`kubectl cp` into a debug pod using the identical
`alpine/helm:3.21.2` image (9/9 again) — the difference turned out to
be that `kubectl cp` copies the local filesystem directly, bypassing
git entirely. The real root cause: a **personal global gitignore rule**
(`~/.gitignore_global`, `*secrets*`) was matching the
`k8s/sealed-secrets/` directory name and had silently excluded it from
every commit since PX-009 — `git log --all -- k8s/sealed-secrets/values.yaml`
confirmed empty, and `git ls-tree` against the exact commit Jenkins
checked out confirmed the file was genuinely absent from that tree. The
file only ever existed on local disk; the real repo on GitHub never had
it. Fixed by adding an explicit `!k8s/sealed-secrets/` override to this
project's own `.gitignore`, then committing the file for real for the
first time. Hardened `scripts/helm-lint-values.sh` regardless of root
cause — missing files now fail loudly (`ERROR` + nonzero exit) instead
of silently skipping, with a final linted-count assertion as a second
line of defense. Mutation-tested: hid the file, confirmed the script
exits 1 with both error messages; restored it, confirmed `git status`
clean.

**Process note, not blocking:** one commit during this ticket
(`f00ffe4`, the script hardening fix) landed directly on `master`
instead of a feature branch — caught immediately, disclosed, left
as-is per explicit instruction rather than force-pushing to fix it.
Branching discipline resumed for the rest of this ticket's work.

**Acceptance criteria:**
- [x] Jenkins reachable via nginx-ingress — necessary, not sufficient
      on its own; does not close this ticket by itself
- [x] `Jenkinsfile` committed to this repo defining a pipeline with
      stages for `terraform validate`, `ansible-lint`, and a Helm chart
      lint (`helm lint` against each chart's values under `k8s/`)
- [x] Jenkins Kubernetes plugin configured with a pod template for
      dynamic build agents, pinned to `wk-2`
- [x] A manually-triggered pipeline run completes successfully, all 3
      stages green — verified via console log: 9/9 charts linted (after
      the sealed-secrets fix above), `ansible-lint` passes at the
      `production` profile, zero `ERROR` lines, `Finished: SUCCESS`.
      `job/proxmox-iac-ci/config.xml` confirms the `pollSCM('H/5 * * * *')`
      trigger from the Jenkinsfile is genuinely registered
      (`hudson.triggers.SCMTrigger`, `spec: H/5 * * * *`) — **the actual
      SCM-poll-triggered run (not manual) is still pending**: this very
      commit is the real push it needs to detect. Will verify the
      resulting build's cause via the API (`Cause$SCMTriggerCause`, not
      `UserIdCause`) in a follow-up commit once observed, not assumed.
- [x] Build agent pod confirmed ephemeral — observed directly via
      `kubectl get pods` during builds #3-#5: a `proxmox-iac-ci-N-...`
      pod appears mid-build (4/4 containers Running) and is gone by the
      time the build finishes, every time, without manual cleanup

---

## Landing page, GitOps (not yet ticketed in detail)

Per `docs/SPEC.md` build order §7, Phases 7–8 (landing page, ArgoCD
retrofit) will get their own PX-0NN tickets written just before each
phase starts, same as PX-004 through PX-013 — not written far in
advance of the work, so acceptance criteria reflect what's actually known
at the time.

## Stretch (post-MVP, not blocking)

- Longhorn distributed storage, replacing local-path for Postgres/Redis PVs
- MetalLB for a real LoadBalancer IP instead of NodePort
- Postgres backup story (WAL-E/WAL-G) via the Zalando operator
- CI action version pinning audit once workflows exist for a full cycle
  (same class of issue as `project-template`'s PT-008)

---

## Ticket status

| Ticket | Title | Status |
|---|---|---|
| PX-001 | Repo scaffold | DONE |
| PX-002 | CI + lint tooling | DONE |
| PX-003 | Cloud-init template on Proxmox | DONE |
| PX-004 | Terraform module skeleton | DONE |
| PX-005 | Terraform VM resource definitions | DONE |
| PX-006 | Terraform state decision | DONE |
| PX-007 | Ansible inventory + roles skeleton | DONE |
| PX-008 | k3s cluster bring-up | DONE |
| PX-009 | Core services (ingress/Redis/Postgres/Sealed Secrets) | DONE |
| PX-010 | Observability (in-cluster Prometheus + Grafana) | DONE |
| PX-011 | Reconcile scaffold against real project-template | DONE |
| PX-012 | Interview walkthrough doc | DONE |
| PX-013 | Jenkins CI (Helm) with a real pipeline | OPEN |

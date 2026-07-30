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

**Status:** IN PROGRESS — roles written, lint/syntax-verified; the real
`ansible-playbook` run (no `--check`) deliberately not executed yet,
same gate as `terraform apply` (see below).

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

**Deliberately NOT run for real yet:** this is also where PX-007's SSH
hardening tasks (disable password auth, disable root login) run for the
first time for real, alongside the actual k3s install across all 3
VMs — a real, state-changing action against every layer this project
depends on (SSH access + the cluster itself), gated behind explicit
confirmation the same way `terraform apply` was.

**Acceptance criteria:**
- [x] `ansible-lint` passes on the updated roles at the `production`
      profile
- [x] `ansible-playbook --syntax-check` passes clean
- [ ] `kubectl get nodes` (run from cp-1 or with kubeconfig pulled locally)
      shows 3 Ready nodes
- [ ] End-to-end: clean `terraform apply` + `ansible-playbook` run produces
      a working cluster with zero manual steps

---

## PX-009 — Core services (ingress, Redis, Postgres, Sealed Secrets)

**Status:** OPEN

**Description:**
nginx-ingress via Helm (Traefik confirmed disabled), Redis via Bitnami
Helm chart, Zalando Postgres Operator + one provisioned `postgresql` CR,
Sealed Secrets controller with at least one real secret sealed and
committed instead of left in plaintext values files.

**Acceptance criteria:**
- [ ] Test route through nginx-ingress works
- [ ] Redis reachable from a test pod
- [ ] Postgres CR provisions successfully, connection verified
- [ ] At least one `SealedSecret` committed and decrypting correctly in-cluster

---

## PX-010 — Observability extension

**Status:** OPEN

**Description:**
kube-state-metrics + node-exporter deployed to the new cluster; existing
home-lab Prometheus scrape config updated; Grafana dashboard added
showing the new cluster's node/pod health.

**Acceptance criteria:**
- [ ] Existing Prometheus shows targets up for all 3 new nodes
- [ ] Grafana dashboard renders live data from the new cluster

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

## Jenkins, landing page, GitOps (not yet ticketed in detail)

Per `docs/SPEC.md` build order §7, Phases 6–8 (Jenkins, landing page,
ArgoCD retrofit) will get their own PX-0NN tickets written just before
each phase starts, same as PX-004 through PX-010 — not written far in
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
| PX-008 | k3s cluster bring-up | OPEN |
| PX-009 | Core services (ingress/Redis/Postgres/Sealed Secrets) | OPEN |
| PX-010 | Observability extension | OPEN |
| PX-011 | Reconcile scaffold against real project-template | DONE |
| PX-012 | Interview walkthrough doc | DONE |

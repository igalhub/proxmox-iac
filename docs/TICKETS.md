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

**Correction (2026-07-31) — missing `qemu-guest-agent`, surfaced by a
real Proxmox UI incident:** wk-1 and wk-2 both showed ~100% memory usage
in the Proxmox UI. Diagnosed as PM before touching anything: inside both
guests, `free -h` showed 6.4-6.6Gi *available* of 7.8Gi, `kubectl top
nodes` showed 13-17% real usage, and node `Allocated resources` showed
requests at 8% — every real number said this wasn't a resource problem.
Root cause: `terraform/vms.tf` declares `agent { enabled = true }`
(PX-005), telling Proxmox to expect a guest agent, but this ticket's
`common` role never installed one — `qm agent 110/111/112 ping` all
returned `"QEMU guest agent is not running"` (exit 255). Without it,
Proxmox falls back to a host-side KVM view where any touched page
(including Linux's own aggressive disk cache — 5.4Gi/5.0Gi of
`buff/cache` on wk-1/wk-2) reads as "used," pinning the gauge near
100%. Same pattern as the PX-008 control-plane taint gap: something
declared on one side (Terraform) was never backed by anything on the
other (Ansible), and neither ticket's acceptance criteria checked for
it directly.

**Fix applied, partially confirmed — documented honestly, not spun as
fully resolved:**
1. Added `qemu-guest-agent` to the `common` role's package list
   alongside `curl`/`ca-certificates`, plus a task ensuring the systemd
   service is `enabled`/`started`
   (`ansible/roles/common/tasks/main.yml`). `ansible-lint` clean at
   `production` profile. `ansible-playbook site.yml --check --diff` run
   first — confirmed the apt install would land cleanly (`liburing2` as
   the only additional dependency, nothing unexpected); the systemd
   task's own check-mode failure ("Could not find the requested service"
   — the service can't exist yet in a dry run) is the same class of
   known check-mode limitation this ticket already documented for
   `authorized_key` above, not a new bug.
2. Applied for real via `ansible-playbook site.yml` against all 3 hosts
   (cp-1 included — same gap existed there, `agent.enabled=true` applies
   uniformly). **Verified, not assumed:** `qm agent 110/111/112 ping` now
   all return exit 0 on every VMID (previously all three failed);
   re-running the full playbook a second time reported `ok` (not
   `changed`) for both the package and service tasks — real idempotency,
   confirmed, not inferred from `state: present`/`enabled: true` alone.
3. **The Proxmox-UI-accuracy hypothesis this fix was meant to prove did
   NOT hold up under real observation.** Polled Proxmox's own UI-facing
   API (`pvesh get .../status/current`) every 15s for 5 minutes (20
   polls): wk-1 and wk-2 never moved off `100.5%`/`100.4%` — flat,
   zero drift, not a slow convergence. cp-1 did show a different reading
   post-fix (`76.2%`, `3.27GB/4GB`) but no real pre-fix baseline was
   captured for cp-1 specifically, and that number doesn't cleanly match
   `free -h`'s "used" or "total minus available" either — so it is
   **not** claimed as evidence the fix worked, just noted as an
   unexplained data point. Confirmed separately that memory ballooning
   is fully disabled (`balloon: 0` in `terraform/vms.tf`) on all three
   VMs, which was always going to be a second variable regardless of the
   guest agent.

**Decision: park the display question, don't chase it further right
now.** Leading unverified theory: Proxmox may negotiate memory-stat
capability with the guest agent over the virtio-serial channel at VM
*boot* time, and installing/starting the agent live, after boot, may not
retroactively activate it without a reboot (or without enabling the
separate `balloon` device mechanism instead). Neither was tested — both
are further disruptive, state-changing actions beyond what this
correction set out to do, and forcing a reboot solely to test a
monitoring-display theory isn't worth the disruption to running
workloads (Postgres/Redis on wk-1, Jenkins on wk-2). **Explicitly not
an operational question:** whether there's *real* memory pressure was
already answered directly and independently of what Proxmox's gauge
shows — `kubectl top nodes` (13-17%), `Allocated resources` (8%
requests), and `free -h` (6.4-6.6Gi available) all agree there is none.
This is a cosmetic monitoring-display issue, not a resource problem.
Next step, opportunistic rather than forced: if either wk-1 or wk-2
reboots for an unrelated real reason (kernel update, host maintenance),
check whether its Proxmox memory reading becomes accurate afterward —
that would confirm or rule out the boot-time-negotiation theory for
free, without manufacturing a disruption just to test it.

**qemu-guest-agent install itself stands on its own merits** regardless
of the display question — it's also what enables clean guest shutdown,
`qm exec`, and consistent snapshots, none of which worked before this
fix either.

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

**Status:** DONE

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

**Real SCM-poll-triggered run, verified (2026-07-31):** build #6's merge
commit (`1380090`, PR #23) was deliberately left as the real push for
`pollSCM('H/5 * * * *')` to detect on its own — not manually triggered.
Polled the job API afterward rather than assuming: build **#7**'s
`causes[]._class` is `hudson.triggers.SCMTrigger$SCMTriggerCause`
(`"Started by an SCM change"`), not `UserIdCause`, and its `changeSets`
correctly attributes commit `b1818a2` (part of that same merge). Console
log for #7 checked directly, not inferred from #6: all 9
`--- helm lint: ... ---` blocks present, each `0 chart(s) failed`,
`ansible-lint` "Passed: 0 failure(s), 0 warning(s)" at the `production`
profile, `Finished: SUCCESS`. This is the one criterion that could not be
satisfied by a manual run by definition — now closed with direct API and
console evidence, not the Jenkinsfile's trigger declaration alone.

**Acceptance criteria:**
- [x] Jenkins reachable via nginx-ingress — necessary, not sufficient
      on its own; does not close this ticket by itself
- [x] `Jenkinsfile` committed to this repo defining a pipeline with
      stages for `terraform validate`, `ansible-lint`, and a Helm chart
      lint (`helm lint` against each chart's values under `k8s/`)
- [x] Jenkins Kubernetes plugin configured with a pod template for
      dynamic build agents, pinned to `wk-2`
- [x] A real pipeline run completes successfully, all 3 stages green,
      triggered by SCM polling against a real push — not a manual
      trigger. Verified via the Jenkins API: build #7's cause is
      `hudson.triggers.SCMTrigger$SCMTriggerCause`, result `SUCCESS`;
      console log confirms 9/9 charts linted, `ansible-lint` clean,
      `terraform validate` clean (same commit's Terraform inputs
      unchanged since build #6, which already exercised that stage
      directly). See "Real SCM-poll-triggered run, verified" above.
- [x] Build agent pod confirmed ephemeral — observed directly via
      `kubectl get pods` during builds #3-#5: a `proxmox-iac-ci-N-...`
      pod appears mid-build (4/4 containers Running) and is gone by the
      time the build finishes, every time, without manual cleanup

---

## PX-014 — Landing page (live Prometheus metrics, real app)

**Status:** DONE

**Description:**
A small, real app — not a static page — that queries the in-cluster
Prometheus's HTTP query API (`/api/v1/query`) directly and renders
cluster health (node count/status, pod status summary, a resource-usage
metric) as a live-updating page, reachable via nginx-ingress. Per
`docs/PRD.md`, this is the project's own "here's proof it's alive"
artifact, so it has to genuinely reflect the cluster's current state,
not a canned screenshot-equivalent.

**Language/framework — decided, not left open:** Python/FastAPI, single
container. `docs/SPEC.md` §2 listed FastAPI or Node/Express as options;
FastAPI chosen here to keep the stack's languages minimal (this project
is otherwise Terraform/Ansible/YAML/bash — no Node anywhere yet) and
because `httpx`+Jinja2 is enough to hit Prometheus's HTTP API and render
one page without pulling in a frontend build toolchain for what's
deliberately a small app.

**Deployment shape — decided:** plain Kubernetes manifests (Deployment +
Service + Ingress) under `k8s/landing-page/`, applied directly — not a
Helm chart. Every other `k8s/<component>/` directory so far holds
*values* for an upstream chart; there is no upstream chart for a custom
app written in this repo, so a Helm chart here would just be
boilerplate wrapping manifests nobody else consumes. This also sets up
cleanly for PX-015 (ArgoCD retrofit), which manages plain manifests and
Helm releases both — no rework needed later.

**Image build/registry — decided:** built from a `Dockerfile` in
`landing/`, pushed to `ghcr.io/igalhub/proxmox-iac-landing`, tagged with
the git commit SHA it was built from (never `latest`) so the committed
manifest pins a real, reproducible image — consistent with this
project's "provisioned as code" posture (PX-006 made the same call for
Terraform state: name the trade-off, don't leave it implicit).

**Build/push mechanism — revised before implementation (Developer
review):** originally scoped as a manual step to avoid mixing an app
change with a CI change in one ticket. Reconsidered: PX-013 already
stood up Jenkins with a real SCM-polling pipeline specifically so this
project's own components get real CI/CD, not just Terraform/Ansible
linting (`docs/PRD.md`'s own stated goal) — a manual `docker build/push`
for the one component that's actually *this project's own software*
would be a real gap in that story, not a scope-creep risk. Folded in as
this ticket's own scope instead of deferred, since the two are the same
change (a landing page with no way to actually publish its image isn't
a complete deployable artifact).

Mechanism: `Jenkinsfile` gets a new stage using **kaniko**
(`gcr.io/kaniko-project/executor`), not `docker build` — the existing
Jenkins agent pod template (PX-013) runs as unprivileged sidecar
containers with no Docker daemon available, and kaniko builds/pushes
OCI images from a Dockerfile without one, fitting the same ephemeral
pod-agent pattern already in use rather than requiring
Docker-in-Docker/privileged pods. Needs a real ghcr.io credential (a
GitHub PAT scoped to `write:packages`) — sealed and surfaced via the
`kubernetes-credentials-provider` plugin, same pattern PX-013 used for
the GitHub deploy key (`k8s/jenkins/jenkins-ghcr-sealedsecret.yaml`),
never stored as plaintext in Jenkins' own credential store or this
repo. Runs on every pipeline execution (same as the existing lint
stages — no path-based conditional for this first pass, kept simple).

**Placement/sizing:** pinned to `wk-1` via `nodeSelector`, consistent
with the rest of wk-1's always-on workloads (`docs/SPEC.md` §3 table).
Confirmed live via `free -h` on wk-1 before sizing, not assumed: **6.6Gi
available** of 7.8Gi total, with Postgres/Redis/nginx-ingress/Prometheus/
Grafana already running there — comfortable headroom for a single small
Python container. Proposed: requests `64Mi`/`50m`, limit `128Mi`/`100m`
— generous relative to the app's actual footprint since headroom isn't
the constraint here (unlike PX-013's tighter wk-2 sizing call); confirm
against real observed usage after deployment and adjust if it's
noticeably over- or under-sized.

**CI coverage:** this is the first custom Python code in the repo — the
existing CI workflow (`shellcheck`/`terraform`/`ansible-lint`) doesn't
touch it. Per this repo's hard rule ("CI must be green before merge, no
exceptions"), add a CI job that lints the new code (`ruff`) before this
ticket's own PR can merge — not deferred to a follow-up ticket, since
merging Python with zero CI coverage on day one would violate that rule
on this ticket's own PR.

**No new secrets (revised):** originally assumed no `SealedSecret` was
needed since Prometheus itself has no auth. That held for the app's own
runtime access, but the *image* turned out to need one: `ghcr.io`
packages default to private (inherit repo visibility), so the cluster's
kubelet needs pull credentials too, not just Jenkins' push credentials.
Considered making the package public instead (simpler, no pull secret)
— before deciding, checked `landing/Dockerfile` and every file under
`landing/` line-by-line: only `requirements.txt`, `main.py`,
`templates/index.html` ever get `COPY`'d in, no `ARG`/`ENV` secrets, no
`.env`, nothing sensitive in any layer, so either choice was safe
content-wise. Kept private anyway (more conservative default) and
reused the same push-credential PAT for a second, separate
`kubernetes.io/dockerconfigjson` secret
(`k8s/landing-page/ghcr-pull-sealedsecret.yaml`) — not a new PAT, since
classic tokens can't be scoped narrower than repo-unscoped anyway,
so a second token wouldn't shrink the real blast radius.

**Real run, verified end to end (2026-07-31):** PR #30's merge commit
(`03d16db`) was the real push. Confirmed via the Jenkins API, not
assumed: build #14's cause is `hudson.triggers.SCMTrigger$SCMTriggerCause`
matching that exact commit, result `SUCCESS`. Console log shows kaniko's
real push: `Pushed ghcr.io/igalhub/proxmox-iac-landing@sha256:a7c6f5b...`.
Independently confirmed pullable — not trusted from the log line alone —
via `github.com/igalhub?tab=packages` (the `gh` CLI's own token lacked
`read:packages` scope, so this was checked directly): a version tagged
`03d16db275a7ce0a1b47d8a24b0555ffdf20baa0` is really there. Worth noting
for anyone repeating this: a PAT-pushed package lands under the
*user's* packages, not automatically linked to the repo's own Packages
sidebar — that had briefly looked like a failed push before finding it
in the right place.

`k8s/landing-page/deployment.yaml` written with that exact SHA tag,
applied, and the pull secret worked on the first attempt — no
`ImagePullBackOff`. Pod `Running` on `wk-1`, `0` restarts, `42Mi` memory
against the `128Mi` limit. Re-ran the live-data proof against the
*deployed* pod specifically (not just the earlier local dev run):
scaled `postgres-operator` to 2 replicas, watched the page's `Running`
count move `17 → 18` through the real `status.lab.test` ingress path
after Prometheus's scrape interval caught up, scaled back down after.

**Acceptance criteria:**
- [x] Landing page reachable via nginx-ingress at `status.lab.test` —
      necessary but not sufficient on its own; does not close this
      ticket by itself
- [x] Container image built and pushed by a new Jenkins pipeline stage
      (kaniko), not a manual `docker build`/`push` — to
      `ghcr.io/igalhub/proxmox-iac-landing`, tagged with the git commit
      SHA it was built from. Verified via a real, SCM-poll-triggered
      pipeline run (build #14, `SCMTrigger$SCMTriggerCause`) that
      completed successfully, and by independently confirming the
      exact SHA-tagged image exists in `github.com/igalhub?tab=packages`
      (not trusting the "pushed" log line alone)
- [x] ghcr.io push credential (GitHub classic PAT, `write:packages`+
      `read:packages`) sealed and surfaced as a real Jenkins credential
      via `kubernetes-credentials-provider`, verified via the
      credentials API the same way PX-013 verified the GitHub deploy
      key ("Username with password", `kubernetes` store) — never
      plaintext in Jenkins' credential store or this repo
- [x] The deployed manifest's image tag matches the SHA the pipeline
      actually pushed for that commit — `k8s/landing-page/deployment.yaml`
      references `03d16db275a7ce0a1b47d8a24b0555ffdf20baa0` exactly,
      the real tag from build #14
- [x] Page queries the in-cluster Prometheus's real HTTP API
      (`/api/v1/query`) at request time — not hardcoded or mocked data.
      Verified twice: once locally before deployment, and again against
      the actual deployed pod by scaling `postgres-operator` and
      watching the displayed `Running` count change through the real
      ingress path
- [x] Page shows, at minimum: node count/status, a pod status summary,
      and one resource-usage metric (CPU or memory) — each value
      cross-checked against querying Prometheus directly for the same
      PromQL expression during local verification, matched
- [x] Page auto-refreshes without a manual browser reload (`<meta
      http-equiv="refresh" content="10">`, confirmed present in the
      real rendered HTML)
- [x] Deployed via plain Deployment + Service + Ingress manifests
      committed under `k8s/landing-page/`, pinned to `wk-1` via
      `nodeSelector` — confirmed via `kubectl get pod -o wide`
- [x] CI lints the new Python code (`ruff`) and this lint job is green
      on the ticket's own PRs
- [x] Real deployment verified via `kubectl` — pod `Running`, `0`
      restarts, `42Mi` memory against the `128Mi` limit, not just
      "manifest applied" exit code

---

## PX-015 — ArgoCD retrofit

**Status:** OPEN

**Background:** Per `docs/SPEC.md` build order §7 item 8, everything from
step 4 onward — nginx-ingress, Redis, Postgres (Zalando operator),
kube-state-metrics, node-exporter, Prometheus + Grafana, Jenkins, the
landing page, and Sealed Secrets itself — is currently a one-off `helm
install`/`kubectl apply` release, not managed by anything. This ticket
retrofits ArgoCD as the GitOps controller reconciling all of it against
this repo going forward, per `docs/SPEC.md` §2's stated rationale (web
UI for demoing sync status/diffs/health, not just describing GitOps).

**Description:**
ArgoCD deployed via its own Helm chart on `wk-1` (per `docs/SPEC.md`'s
role split, grouped with the other always-on data/apps services, kept
off `wk-2` to avoid contending with Jenkins builds), exposed behind
nginx-ingress at `argocd.lab.test`. Existing Helm releases and the
landing page's raw manifests get adopted into ArgoCD `Application`
resources pointing at this repo's `k8s/` directory rather than
reinstalled — real adoption, verified against the live cluster, not
assumed to be clean just because it's the documented pattern.

**Decisions (locked in 2026-07-31, review feedback incorporated):**

1. **Repo access for ArgoCD:** its own dedicated read-only SSH deploy
   key, separate from Jenkins's (`k8s/jenkins/jenkins-github-deploy-key-sealedsecret.yaml`)
   — not reused. Same sealing pattern: generate a dedicated ed25519 key,
   add as a GitHub read-only deploy key via `gh api repos/.../keys`,
   seal as a `kubernetes.io/ssh-auth`-shaped `SealedSecret` matching
   ArgoCD's expected repo-credential schema (`k8s/argocd/argocd-github-deploy-key-sealedsecret.yaml`).
   Two independent consumers get two independent credentials, so a
   compromise or accidental leak of one doesn't hand out access on
   behalf of the other.
2. **Application layout: app-of-apps.** One root `Application`
   (`k8s/argocd/root-app.yaml`, pointed at `k8s/argocd/apps/`) manages a
   child `Application` manifest per service (nginx-ingress, Redis,
   Postgres operator, kube-state-metrics, node-exporter, Prometheus,
   Grafana, Jenkins, Sealed Secrets, landing page). Justification specific
   to this project: the whole premise since PX-001 has been "provisioned
   as code end to end" — `terraform apply` rebuilds the VMs, `ansible-playbook`
   rebuilds the cluster, and app-of-apps is the piece that makes
   rebuilding *everything running inside* a single reviewed action too
   (sync the root `Application`) instead of nine separate ones. Flat,
   independent `Application`s would leave that last mile as a manual
   checklist — the same gap this whole repo exists to close.
3. **Sync policy: manual for every `Application`, root included — no
   auto-prune or self-heal anywhere in this initial retrofit.**
   Consistent with every other state-changing action in this project
   requiring explicit go-ahead (`CLAUDE.md`'s Reversibility section, the
   per-ticket "never delegate destructive commands" rule): an
   auto-synced `Application` would apply a Git change to the live
   cluster with no human in the loop, which is exactly the class of
   action this project's own conventions gate behind explicit approval
   everywhere else. `docs/PRD.md`'s success criterion updated
   accordingly (2026-07-31) — reconciliation happens via a *reviewed*
   sync, not an unattended one; that's the deliberate choice, not an
   unmet criterion. Revisit auto-sync per-`Application` in a future
   ticket once the manual workflow itself has been exercised for real.
4. **Adoption order:** lowest-risk services first — landing page
   (stateless, already behind its own Deployment) — before touching
   Postgres/Redis, so a bad adoption is caught on something disposable.

**Partial slice landed 2026-07-31 (branch
`feature/PX-015-argocd-landing-page-adoption`, PR #35; cosmetic fix PR
#36) — ArgoCD installed and the landing page adopted. Second partial
slice, same day (branch `feature/PX-015-kube-state-metrics-adoption`,
PR #37) — kube-state-metrics adopted too, second-lowest-risk after the
landing page per decision 4 (pure metrics exporter, no ingress, no
dependents). Third partial slice, same day (branch
`feature/PX-015-node-exporter-adoption`) — node-exporter adopted, first
DaemonSet (vs. Deployments so far). Fourth partial slice, same day
(branch `feature/PX-015-prometheus-adoption`) — Prometheus adopted,
first release with a PersistentVolumeClaim. Fifth partial slice, same
day (branch `feature/PX-015-grafana-adoption`) — Grafana adopted,
second PVC, first Ingress among the Helm-sourced adoptions. Sixth
partial slice, same day (branch `feature/PX-015-jenkins-adoption`) —
Jenkins adopted, highest-stakes so far: first StatefulSet, real build
history/config on its PVC, three standalone SealedSecrets it depends on
correctly left out of the Application. Seventh partial slice, same day
(branch `feature/PX-015-postgres-operator-adoption`) — Postgres Operator
adopted: despite the name, only the operator's stateless controller
Deployment, no PVC — the actual data-bearing `proxmox-iac-pg` postgresql
CR lives separately in the `postgres` namespace, was never part of this
ticket's adoption list, and this Application touches zero persisted
data. This is deliberate, not a shortcut: the remaining 3 services
(nginx-ingress, Redis, Sealed Secrets) are still plain `helm
install`/`kubectl apply` and their adoption is separate future work. Do
not treat this ticket as DONE and do not check the "one child
`Application` per existing release" box until that full adoption
actually happens.**

kube-state-metrics, node-exporter, Prometheus, Grafana, and Jenkins
adoption all used a multi-source `Application`
(`k8s/argocd/apps/kube-state-metrics.yaml`,
`k8s/argocd/apps/node-exporter.yaml`, `k8s/argocd/apps/prometheus.yaml`,
`k8s/argocd/apps/grafana.yaml`, `k8s/argocd/apps/jenkins.yaml`): the
Helm chart pulled straight from its upstream repo, pinned to the exact
version already live (`8.0.0`/`4.56.1`/`29.20.0`/`10.5.15`/`5.9.45`),
with the values file staying in this repo via the standard
`ref: values` pattern — rendered manifests matched what was already
running byte-for-byte (confirmed: same release name produces identical
resource names, including PVCs and, for Grafana/Jenkins, their
Ingress), so each sync only changed ownership/tracking metadata, never
the resources. Verified via real sync, twice each (pre-merge on the
feature branch, post-merge against `master`): `Synced`/`Healthy`, all
tracked resources `Synced`, every pod UID/restarts/age unchanged before
and after (kube-state-metrics `13dedb1e-...`; node-exporter's DaemonSet
across all 3 nodes — `db678154-...`/`6c05e6df-...`/`02a47c98-...`, all 0
restarts; Prometheus `fee155b5-...`; Grafana `23637cc9-...`; Jenkins
`61f35740-...`), and the real functional check for each — Prometheus
scrape targets confirmed `up` for the two exporters; for Prometheus
itself, the PVC's UID/backing volume unchanged plus a direct query for
`up` at a timestamp ~30 minutes before the Application existed still
returning real data, proving the TSDB was genuinely untouched; for
Grafana, its own PVC UID/volume unchanged, the real ingress health
endpoint returning `HTTP 200`, and both provisioned dashboards still
present via the authenticated API; for Jenkins, the PVC UID/volume
unchanged, the real ingress `/login` returning `HTTP 200`, all 26
existing builds of the `proxmox-iac-ci` job still present via the
authenticated API, and both `kubernetes-credentials-provider`-surfaced
credentials (`jenkins-github-deploy-key`, `ghcr-push-token`) still
present — proving Jenkins' own config store, build history, and
credential wiring all survived the adoption of its highest-stakes
resource (a StatefulSet) intact. Diff previewed via
`managed-resources` before syncing — confirmed the StatefulSet's image
and replica count were unchanged and the PVC's only differences were
server-populated defaults, not a real change, before committing to the
sync.

Postgres Operator adoption (`k8s/argocd/apps/postgres-operator.yaml`)
used the same multi-source pattern, chart pinned to `2.0.1`. This
Application also templates the operator's 3 CRDs
(`postgresqls.acid.zalan.do` etc.) — already existed, so the sync only
updated their ownership/tracking metadata, same as every other
resource. Verified: operator pod UID `a3a4e4f2-...` unchanged, all 11
tracked resources `Synced`, and — the real functional check, since the
operator's own state doesn't say much about the database it manages —
the actual `proxmox-iac-pg` postgresql CR and its pod confirmed
completely untouched (`Running`, 0 restarts, unchanged 17h age) and
`pg_isready` against the live pod still reports accepting connections.

One correction to decision 1's wording: the sealed secret is ArgoCD's
real repo-credential secret shape (`Opaque`, labeled
`argocd.argoproj.io/secret-type: repository`, keys `type`/`url`/`sshPrivateKey`),
not a literal `kubernetes.io/ssh-auth` typed secret — ArgoCD only
recognizes repo credentials in that shape, confirmed live via
`GET /api/v1/repositories` showing `connectionState.status: Successful`
against the real private repo.

**Acceptance criteria:**
- [x] ArgoCD installed via Helm on `wk-1`, reachable at `argocd.lab.test`
      through nginx-ingress — confirmed `kubectl get pods -n argocd -o wide`
      (all pods on `wk-1`) and `curl -H "Host: argocd.lab.test"` through
      the real nginx-ingress NodePort returning HTTP 200
- [x] ArgoCD has its own dedicated read-only deploy key, confirmed
      working against a real sync (not just secret-exists) — GitHub deploy
      key id 158880510, distinct from Jenkins's (158838165); repo
      connection state `Successful` via the ArgoCD API
- [ ] Root `Application` (app-of-apps) manages one child `Application`
      per existing release — **partial**: landing-page, kube-state-metrics,
      node-exporter, Prometheus, Grafana, Jenkins, and Postgres Operator
      adopted so far, all without a disruptive reinstall — confirmed via
      `kubectl get pods`: identical pod UID(s), 0 restarts, unchanged age
      before and after each real sync (Prometheus, Grafana, and Jenkins
      additionally confirmed via each PVC's UID/backing volume unchanged,
      Jenkins further confirmed via intact build history and
      credentials, Postgres Operator further confirmed via the actual
      `proxmox-iac-pg` postgresql CR/pod being completely untouched and
      still accepting connections). The other 3 services remain
      un-adopted and un-stubbed.
- [x] Every `Application`, including the root, set to manual sync —
      both `root-app.yaml` and `apps/landing-page.yaml` have `syncPolicy: {}`,
      confirmed no auto-prune/self-heal
- [x] Each `Application` shows `Synced`/`Healthy` in the ArgoCD UI after
      a real, manually-triggered sync against actual live state — verified
      via the ArgoCD API against the feature branch pre-merge (root-app's
      `targetRevision` temporarily pointed at the branch since
      `k8s/argocd/apps/` doesn't exist on `master` until this PR merges;
      committed files target `master`, matching the intended
      steady-state — a follow-up sync against `master` happens right after
      merge)
- [ ] `docs/SPEC.md` build order and architecture diagram — not yet
      updated for this partial slice; will land with the full adoption
      ticket once all 10 services are under ArgoCD, not piecemeal per slice
- [ ] `docs/PRD.md` ArgoCD success criterion wording — same, deferred to
      the full-adoption close-out

## PX-016 — Resolve Proxmox memory-gauge inaccuracy (wk-1/wk-2)

**Status:** OPEN — not blocking, no urgency; do when convenient, not
before PX-014/PX-015.

**Background:** PX-007's `qemu-guest-agent` correction fixed the missing
agent (install verified, `qm agent ping` succeeds on all 3 VMs) but did
**not** fix Proxmox's UI still reporting wk-1/wk-2 at ~100% memory — 5
minutes of polling showed zero change after the live install. Leading
theory: Proxmox negotiates memory-stat capability with the guest agent
over virtio-serial at VM *boot* time; installing/starting it live,
post-boot, may not retroactively activate it. **Explicitly not an
operational problem** — real usage is already confirmed fine independent
of this gauge (`kubectl top nodes`: 13-17%, `Allocated resources`: 8%
requests, `free -h`: 6.4-6.6Gi available). This ticket exists to either
fix a cosmetic annoyance or formally stop chasing it — not because
there's a resource risk.

**Plan, in order — stop and reassess between each step rather than
running straight through:**

1. **Restart wk-1 and wk-2** (one at a time; wk-1 hosts Postgres/Redis so
   confirm no in-progress work first; wk-2 hosts Jenkins so avoid mid-build).
   This is a real, disruptive action against live workloads — needs
   explicit go-ahead per ticket, same as every other state-changing step
   in this repo, not bundled into a "just try it" pass.
2. **Check the Proxmox memory reading for each** after it comes back up.
   If accurate now: theory confirmed, done — document and close.
3. **If still showing ~100% after restart:** check `pvestatd`'s own logs
   on the Proxmox host (`journalctl -u pvestatd`) for an actual error
   before changing anything else — cheap, non-disruptive, might explain
   this directly instead of guessing further.
4. **If inconclusive:** try enabling the balloon device via Terraform
   (non-zero `balloon` in `terraform/vms.tf`, replacing the current
   `balloon: 0`) — the actual purpose-built mechanism for this, separate
   from the guest agent. Confirm via `terraform plan` what this actually
   changes before applying; check whether it needs another reboot to
   take effect cleanly rather than assuming it applies live.
5. **If still unresolved after both real attempts:** stop chasing it.
   Formally document Proxmox's own memory gauge as unreliable for this
   deployment, and designate the in-cluster Grafana (PX-010) — sourced
   from node-exporter running inside each guest, a more direct view than
   anything the hypervisor infers externally — as the authoritative
   source for memory monitoring going forward. This is a legitimate
   closing decision, not a failure to reach one.

**Acceptance criteria:**
- [ ] wk-1 and wk-2 both restarted, memory reading checked immediately after each
- [ ] If inaccurate post-restart: `pvestatd` logs checked for a real error
- [ ] If still inconclusive: balloon-device change proposed via Terraform,
      plan reviewed before apply
- [ ] Either the gauge is confirmed fixed (with the reason documented), or
      a formal decision to rely on in-cluster Grafana instead is recorded
      — ticket closes with one of these two outcomes, not left hanging

---

## PX-017 — Narrow the ghcr.io push token's scope once the repo is public

**Status:** OPEN — not blocking, no urgency; depends entirely on Igal's
own separate decision to make `igalhub/proxmox-iac` public.

**Background:** PX-014 needed a classic GitHub PAT to let Jenkins push
the landing page image to `ghcr.io`. Real, hands-on investigation during
that ticket (not assumed) found: fine-grained PATs don't support GHCR
package operations at all, and classic PATs require the full `repo`
scope alongside `write:packages`/`read:packages` *specifically because
the repo is private* — GitHub couples package write access to full repo
access for private repos. The token currently in use
(`k8s/jenkins/jenkins-ghcr-sealedsecret.yaml`'s underlying PAT, named
"proxmox-iac ghcr push (PX-014)" in GitHub's token settings) therefore
has full read/write access to every private repo on the account, not
just packages — a materially bigger blast radius than the ticket's own
least-privilege intent, accepted at the time as a named, deliberate
trade-off (same pattern as PX-006's Terraform state decision) pending
this follow-up.

**The fix, once the repo goes public:** the `repo`-scope requirement is
specifically a private-repo behavior — once `igalhub/proxmox-iac` is
public, `write:packages`/`read:packages` should stand alone without
needing `repo` at all. At that point:

1. Go to `https://github.com/settings/tokens`, find "proxmox-iac ghcr
   push (PX-014)", **Edit**.
2. Deselect the whole `repo` scope (and all its children) — leave only
   `write:packages` and `read:packages` checked.
3. Save. No new token, no re-sealing needed — narrowing an *existing*
   token's scopes doesn't change its value, so the already-sealed
   secrets (`k8s/jenkins/jenkins-ghcr-sealedsecret.yaml` and
   `k8s/landing-page/ghcr-pull-sealedsecret.yaml`) keep working
   unmodified.
4. Confirm Jenkins can still push after the next real pipeline run
   (build result `SUCCESS`, image tag pushed) — verify the narrowed
   token actually still works, don't assume removing `repo` scope was
   side-effect-free.

**Also worth re-checking at that point (not a separate ticket):**
whether GitHub's fine-grained PAT "Packages" permission has become
available for public repos by then — PX-014 confirmed it wasn't
available for a private repo at the time, but that was never tested
against a public one. If it's available, a fine-grained token scoped to
just this repo would be strictly better than a narrowed classic token
and worth switching to instead of stopping at step 3 above.

**Acceptance criteria:**
- [ ] `igalhub/proxmox-iac` confirmed public (prerequisite, owned by
      Igal, not this ticket)
- [ ] `repo` scope removed from the existing PAT via GitHub's token
      settings, `write:packages`/`read:packages` retained
- [ ] A real pipeline run after the change confirms the push still
      works — not assumed from "the scopes look right"
- [ ] Checked whether a fine-grained, single-repo-scoped token is now
      available for packages on a public repo; if so, note the finding
      here and decide whether to switch (can be a follow-up decision,
      not required to close this ticket)

---

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
| PX-013 | Jenkins CI (Helm) with a real pipeline | DONE |
| PX-014 | Landing page (live Prometheus metrics, real app) | DONE |
| PX-015 | ArgoCD retrofit | OPEN |
| PX-016 | Resolve Proxmox memory-gauge inaccuracy (wk-1/wk-2) | OPEN |
| PX-017 | Narrow ghcr.io push token scope once repo is public | OPEN |

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

**Addendum (2026-08-01) — the parked display question's full resolution,
for anyone reading this ticket in isolation:** the "park it, don't chase
it further" decision above was reopened twice more. **PX-016** tested
the leading theory named here directly (boot-time memory-stat
negotiation) — a graceful reboot did make the gauge accurate, appearing
to confirm it and closing the ticket `DONE`. That conclusion turned out
to be **incomplete**: the reboot's real effect was just resetting the
guest's page cache to empty, which happened to make the gauge look
correct for a few hours — not because the negotiation theory was fully
right, but because the actual root cause (ballooning disabled,
`balloon: 0`, noted here as "a second variable regardless of the guest
agent") was still present the whole time. As the page cache refilled
(normal, healthy Linux behavior — the same `buff/cache` growth this
ticket already identified as the real driver of the ~100% reading), the
gauge drifted back to ~100% again, caught during PX-022. **PX-023**
fixed the actual mechanism: enabled `memory.floating` (Proxmox's real
balloon-floor value) via Terraform, giving Proxmox genuine
memory-pressure telemetry from the guest instead of the `total - free`
fallback this ticket first identified as the culprit. Verified stable
over a multi-hour post-reboot window, not just immediately after
rebooting — the specific gap that made PX-016's conclusion premature.
Three tickets, one underlying story: PX-007 fixed "no data," PX-016
fixed "looks right by accident," PX-023 fixed the actual measurement.

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

**Status:** DONE — closed out 2026-07-31. All 10 services adopted under
ArgoCD, all 7 acceptance criteria verified, final post-merge sync
against `master` confirmed all 11 Applications (root + 10 children)
`Synced`/`Healthy` and every ingress-routed service still reachable
through the readopted nginx-ingress controller. See PRs #35-#47 for the
full trail.

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
data. Eighth partial slice, same day (branch
`feature/PX-015-sealed-secrets-adoption`) — Sealed Secrets controller
adopted, highest-stakes for a different reason than statefulness: it
holds the keypair that decrypts every SealedSecret in the cluster.
Ninth partial slice, same day (branch `feature/PX-015-redis-adoption`)
— Redis adopted: two StatefulSets (primary + replica), two PVCs.
Checked before adopting, not assumed: no application in this repo
(landing page, Jenkinsfile) ever references Redis, and the only key in
the live database was a leftover string from PX-009's own install
verification — nothing downstream actually depends on its persisted
state yet, so despite being "stateful," the real risk here was
materially lower than Jenkins/Sealed Secrets. Tenth and final slice,
same day (branch `feature/PX-015-nginx-ingress-adoption`) —
nginx-ingress adopted, deliberately saved for last as the
highest-blast-radius adoption in the ticket. **All 10 services are now
under ArgoCD. Full adoption complete — this ticket is DONE.**

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

Sealed Secrets controller adoption (`k8s/argocd/apps/sealed-secrets.yaml`)
used the same multi-source pattern, chart pinned to `2.19.1`. The real
risk here isn't statefulness — it's that the controller holds the
keypair decrypting every SealedSecret in the cluster, and a bad sync
regenerating/replacing that keypair Secret would silently break
decryption for everything else at once. That risk is structurally
bounded, not just hoped away: the chart never templates the active
keypair Secret (`sealed-secrets-key<random>`, controller-generated at
first boot with a random name suffix the chart can't predict) —
confirmed via `helm template` producing no `Secret` resource at all,
and independently via `GET /api/v1/applications/sealed-secrets/managed-resources`
showing no `Secret` in this Application's managed set, so no sync this
Application ever performs can touch it. Verified anyway, not just
assumed: the keypair Secret's `tls.crt`/`tls.key` data hashed
byte-for-byte identical (sha256) before and after the real sync, same
Secret UID throughout, controller pod UID unchanged. Real functional
check: sealed a throwaway test secret with `kubeseal` against the
running (post-adoption) controller, applied it, confirmed it decrypted
correctly, cleaned up — proving the exact same keypair is still fully
operational, not just present.

Redis adoption (`k8s/argocd/apps/redis.yaml`) used the same
multi-source pattern, chart pinned to `27.0.18`. Diff previewed via
`managed-resources` before syncing (established discipline for anything
with a PVC since Jenkins): both `StatefulSet`s' image and replica count
unchanged, `volumeClaimTemplate` names matched the existing PVCs'
naming. Verified: both pod UIDs (`redis-master-0`
`37c8eb6d-...`/`redis-replicas-0` `4d0eee79-...`) and both PVC UIDs/
backing volumes unchanged before and after. Real functional check: the
pre-existing `px009-check` key still readable after the sync, and the
master-replica link still `state=online`/`lag=0` — replication itself
proven unbroken, not just the individual pods' identity.

nginx-ingress adoption (`k8s/argocd/apps/nginx-ingress.yaml`) used the
same multi-source pattern, chart pinned to `4.15.1`. Highest blast
radius by design — every other service's ingress traffic, including
ArgoCD's own UI, routes through this single-replica controller. A real,
non-obvious risk was identified and planned around *before* syncing,
not discovered after the fact: this chart bundles Helm hook Jobs
(`pre-install`/`pre-upgrade`/`post-install`/`post-upgrade`) that
regenerate the admission webhook's self-signed TLS cert and patch the
`ValidatingWebhookConfiguration`'s CA bundle — a documented gotcha when
retrofitting GitOps onto ingress-nginx, since ArgoCD translates and
re-runs Helm hooks as its own sync hooks. Theoretical failure mode: if
the Jobs rotated the cert, the already-running controller pod (no
second replica) would keep serving the old one until restarted, and any
new Ingress create/update would get rejected by `failurePolicy: Fail`
in the gap. Planned mitigation, agreed explicitly before syncing: sync,
then one controlled `kubectl rollout restart` in the same sitting,
accepting a brief self-inflicted outage over an indefinite silent
mismatch.

What actually happened, verified rather than assumed either way: the
diff was previewed first (`managed-resources` — same image/replica
count as live, no real Deployment change), then synced. The hook Jobs
genuinely did run (confirmed via `kubectl get events`:
`ingress-nginx-admission-create`/`-patch` both completed), but the
upstream certgen tooling proved idempotent and left the existing cert
untouched — sha256 fingerprint of the `ingress-nginx-admission` Secret's
cert identical before and after. Confirmed directly, not just inferred
from the fingerprint match: a real throwaway test Ingress
(`kubectl create ingress`) was accepted cleanly immediately after the
sync with zero TLS/CA errors. Also confirmed empirically, not just
assumed from Kubernetes' documented update semantics: the NodePort
Service's fixed ports (`30963`/`31395` — used by every curl check
throughout this entire PX-015 body of work) were unchanged after the
sync. Since the mismatch that justified the planned restart was
directly disproven rather than merely absent, the restart was
deliberately skipped — forcing a single-replica ingress outage with no
corresponding benefit would have been the wrong call, confirmed via
explicit check-in rather than silently deciding either way. Controller
pod UID (`bb909938-...`) confirmed unchanged throughout (0 restarts).
Final functional check — the one that actually matters for an ingress
controller, since "the pod is healthy" says nothing about whether
routing still works: every other adopted service's real ingress path
checked through the readopted controller post-sync —
`argocd.lab.test` (`HTTP 200`), `status.lab.test` (`HTTP 200`),
`jenkins.lab.test/login` (`HTTP 200`), `grafana.lab.test/api/health`
(`HTTP 200`).

**Final close-out verification (2026-07-31, after PR #47 merged):** all
11 Applications (`root-app` + 10 children) re-synced against `master`
directly, confirmed `Synced`/`Healthy` across the board via
`kubectl get application -n argocd`. nginx-ingress controller pod UID
and both NodePorts (`30963`/`31395`) confirmed unchanged one more time.
The full ingress sweep (ArgoCD, landing page, Jenkins, Grafana) re-run
against `master`'s actual live state, all four still `HTTP 200` —
closing this ticket on real, re-verified evidence against the merged
state, not just the pre-merge branch checks.

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
- [x] Root `Application` (app-of-apps) manages one child `Application`
      per existing release — **all 10 done**: landing-page,
      kube-state-metrics, node-exporter, Prometheus, Grafana, Jenkins,
      Postgres Operator, Sealed Secrets, Redis, and nginx-ingress, every
      one adopted without a disruptive reinstall — confirmed via
      `kubectl get pods`: identical pod UID(s), 0 restarts, unchanged
      age before and after each real sync (Prometheus, Grafana, Jenkins,
      and Redis additionally confirmed via each PVC's UID/backing volume
      unchanged, Jenkins further confirmed via intact build history and
      credentials, Postgres Operator further confirmed via the actual
      `proxmox-iac-pg` postgresql CR/pod being completely untouched and
      still accepting connections, Sealed Secrets further confirmed via
      its keypair Secret's data hashed byte-for-byte identical
      before/after and a live seal-apply-decrypt round trip still
      working post-adoption, Redis further confirmed via its
      pre-existing key still readable and the master-replica link
      staying `online`/`lag=0` through the sync, nginx-ingress further
      confirmed via every other adopted service's real ingress path
      still resolving `HTTP 200` through the readopted controller).
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
- [x] `docs/SPEC.md` build order and architecture diagram updated to
      reflect ArgoCD as the actual reconciler for all 10 services, not a
      planned/partial one — build order item 8 marked ✅, provisioning
      flow diagram and status header updated
- [x] `docs/PRD.md` ArgoCD success criterion wording confirmed to match
      the manual-sync decision — already accurate as written ("reconciled
      via a reviewed ArgoCD sync"), no change needed, verified rather
      than assumed

## PX-016 — Resolve Proxmox memory-gauge inaccuracy (wk-1/wk-2/cp-1)

**Status:** DONE — closed out 2026-07-31 (wk-1/wk-2), extended same-day
to cp-1 at igalhub's explicit request after the original ticket closed.
Theory confirmed on all three nodes: Proxmox negotiates the guest-agent
memory-stat capability at VM boot time, and the live agent install
(PX-007) never retroactively activated it. A graceful reboot did.

**Correction (2026-08-01, during PX-022):** this ticket's root-cause
conclusion was incomplete. The gauge maxed out again on wk-1/wk-2 with
the guest agent still running continuously since this ticket's own
reboot (no restarts) — meaning the actual cause was never fully
addressed. Real cause, found and tracked in **PX-023**: `balloon: 0` in
`terraform/vms.tf` means Proxmox can't get real memory-pressure stats
from the guest, so it falls back to something close to `total - free`,
which trends toward ~100% on any healthy Linux guest as the page cache
fills (completely normal, reclaimable memory use). The reboot only ever
reset the cache to empty, giving a false "fixed" signal for a few hours.
Left `DONE` rather than reopened/rewritten — the verification performed
here was real and honestly reported at the time, it just didn't run long
enough to catch the cache refilling. History preserved; the actual fix
is tracked in PX-023, not here.

**Verification, wk-1 (VMID 111):** baseline `mem: 8632373248` /
`maxmem: 8589934592` (just over 100%) before restart. Confirmed idle
first — Postgres (`proxmox-iac-pg-0`) and Redis
(`redis-master-0`/`redis-replicas-0`) both 21h uptime, zero restarts, no
in-progress work. `qm reboot 111`, confirmed via guest-agent `uptime -s`
that a real reboot happened (boot time ~5 min prior, vs. the previous
21h uptime). Post-reboot: `mem: 3559424000` (~41%) — accurate. All pods
that were on wk-1 (ArgoCD, ingress-nginx, landing page, Grafana,
Prometheus, Postgres, Redis) came back `Running` with exactly 1 restart
each (a clean node reboot, not a crash), node `Ready`.

**Verification, wk-2 (VMID 112):** checked for an in-progress Jenkins
build before touching it — one was running at the time PX-016 started
(a fresh agent pod, 85s old), so wk-2 was held until it finished, then
re-checked clean before proceeding. Baseline `mem: 8631488512` /
`maxmem: 8589934592`, same ~100%+ pattern as wk-1. `qm reboot 112`,
confirmed via guest-agent boot time. Post-reboot: `mem: 2515034112`
(~29%) — accurate, matching `kubectl top nodes`' real 15%.

**Real bug found and fixed along the way, not just "restart and hope":**
`jenkins-0` crash-looped after the reboot (`CrashLoopBackOff` on its
`init` init-container, exit code 1). Root cause, diagnosed via
`kubectl logs`/`describe`, not guessed: the init container's plugin-copy
step runs `cp` without `-f`; its target, `/var/jenkins_plugins`, is an
`emptyDir` volume whose on-disk directory (under kubelet's local pod
storage) survived the *graceful* VM reboot — unlike a pod deletion, the
node coming back up didn't wipe it. `cp` hit already-existing files,
its interactive overwrite prompts got instant EOF (no stdin in a
container), and it exited 1. Not a data-loss risk — Jenkins's actual
home/config lives on the separate `jenkins` PVC, untouched throughout.
Fixed with a normal, non-destructive `kubectl delete pod jenkins-0`
(StatefulSet recreated it fresh, clean `emptyDir`) — `2/2 Running`,
0 restarts on the new pod. Real functional check after: `HTTP 200` on
`/login` through the actual nginx-ingress NodePort with a
`Host: jenkins.lab.test` header, not just "pod looks fine."

**Extension to cp-1 (VMID 110), out of the ticket's original
wk-1/wk-2-only scope — done at igalhub's explicit request after
independently confirming cp-1 showed the same pattern:** baseline
`mem: 3850276864` / `maxmem: 4294967296` (~90%) vs. `kubectl top nodes`'
real ~28-30%. Higher blast radius than a worker restart — cp-1 is the
sole control-plane node (no HA, a documented `docs/PRD.md` non-goal), so
the API server/scheduler/CoreDNS are briefly unavailable during the
reboot (already-running pods on wk-1/wk-2 keep running throughout, since
kubelet doesn't need the API server for that) — flagged explicitly
before proceeding, explicit go-ahead given. `qm reboot 110`, confirmed
via guest-agent boot time. Post-reboot: API server back up, all 3 nodes
`Ready`, `mem: 1742213120` (~41%) — accurate, matching real usage
(`kubectl top nodes`: 20-31% across all three nodes this time). No
crash-looping pods this run (`metrics-server` restarted and briefly
`0/1` but settled on its own within ~2 minutes). Real functional check:
ArgoCD (API-server-dependent) confirmed fully healthy post-reboot, UI
reachable (`HTTP 200`) through the real ingress path.

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
- [x] wk-1 and wk-2 both restarted, memory reading checked immediately after each
- [x] cp-1 restarted too (extension beyond original scope, igalhub's
      explicit request), memory reading checked immediately after
- [x] If inaccurate post-restart: `pvestatd` logs checked for a real error —
      not needed, both nodes were accurate immediately after their reboot
- [x] If still inconclusive: balloon-device change proposed via Terraform,
      plan reviewed before apply — not needed, resolved at step 2
- [x] Either the gauge is confirmed fixed (with the reason documented), or
      a formal decision to rely on in-cluster Grafana instead is recorded
      — gauge confirmed fixed, reason documented above (guest-agent
      memory-stat capability negotiated at boot, not live-activatable)

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

## PX-018 — Stop relying on a personal global gitignore for `*.tfvars`

**Status:** DONE — closed out 2026-07-31 (PR #51, `6a8ad7d`). Found
during PX-015's independent close-out verification (not part of PX-015's
own scope, filed and implemented separately per this repo's "no bundling
unrelated changes" rule).

**Background:** `terraform/terraform.tfvars` is currently untracked, but
`.gitignore`'s own comment on the `*.tfvars` line says coverage comes
from `~/.gitignore_global` — a personal, unversioned, machine-local file,
not anything this repo itself enforces. That's the identical failure
shape to a bug this project has already hit twice: a personal global
`*secrets*` rule silently excluded `k8s/sealed-secrets/` from every
commit since PX-009 (caught in PX-013), and the same global rule caught
`k8s/argocd/apps/sealed-secrets.yaml` again during PX-015. Both of those
were "content that should be committed getting silently dropped"; this
is the inverse — "content that must never be committed (a Proxmox API
token) has no protection beyond a setting that lives outside the repo
and isn't guaranteed to exist or be configured the same way on a fresh
clone, a different machine, or CI." Same root cause, opposite direction,
worth closing before it's the thing that actually leaks a token instead
of the thing that actually gets silently skipped.

**Description:** Add an explicit `*.tfvars` rule directly to this
repo's own `.gitignore` (keeping the existing `!*.tfvars.example`
negation), matching the pattern already used for `.kubeconfig`/
`.vault_pass` elsewhere in the same file. Remove or correct the comment
claiming global-gitignore coverage is sufficient. Confirm the fix is
real, not just present in the file — `git check-ignore -v` should
attribute the ignore to this repo's `.gitignore`, not `~/.gitignore_global`.

**Acceptance criteria:**
- [x] `.gitignore` has an explicit `*.tfvars` rule, `!*.tfvars.example`
      negation preserved
- [x] `git check-ignore -v terraform/terraform.tfvars` confirms the
      match comes from this repo's `.gitignore` (`.gitignore:12`), not
      the personal global file
- [x] Stale comment claiming global-gitignore coverage removed/corrected
- [x] `git log --all -- terraform/terraform.tfvars` confirmed empty —
      this ticket closed a future risk, not an already-leaked token
      needing separate remediation
- [x] No unrelated changes bundled into this PR — diff was `.gitignore`
      only

---

## PX-019 — CI Action version pinning audit

**Status:** DONE — closed out 2026-07-31 (PR #56). CI confirmed green on
the real PR run using the SHA-pinned actions (all 4 jobs:
`shellcheck`/`terraform`/`ansible-lint`/`ruff`), not assumed from the
diff looking correct.

**Findings:** Both actions used in `ci.yml` were already current at their
pinned major — no version bump was needed: `actions/checkout@v7` (latest
patch `v7.0.1`, published 2026-07-20) and `hashicorp/setup-terraform@v4`
(latest patch `v4.0.1`, published 2026-05-12). Checked deliberately
rather than assumed, given GitHub's active Node.js 20 → 24 runner
migration (default flipped to Node 24 on 2026-06-16, full Node 20
removal 2026-09-16 — squarely mid-migration as of this ticket): both
actions' `action.yml` at their pinned tags already declare
`using: node24`, so neither is affected by the deprecation. Nothing
shifted since PX-013's reactive bump.

**Tag-pinning vs. SHA-pinning decision:** adopted SHA-pinning,
documented here as a deliberate trade-off, not a silent default. Tag
pins (`@v7`) are more readable but mutable — a compromised action could
be re-tagged to point at malicious code without this repo's own history
showing any change. SHA pins are immutable (the actual supply-chain-
security practice at real companies) at the cost of readability, solved
here with an inline `# vX.Y.Z` comment on every pin. Chosen because the
cost is genuinely low (only 2 unique actions across 5 `uses:` lines) and
this project's whole thesis is demonstrating real, defensible production
practices under interview questioning — same reasoning that drove the
Postgres-operator-over-Helm-chart decision (PX-009). All 5 lines in
`.github/workflows/ci.yml` now pin by commit SHA with a version comment:
`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` (×4)
and `hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1`
(×1). Both SHAs confirmed against the real tag refs
(`gh api repos/<org>/<repo>/git/refs/tags/<tag>`), not typed from memory.

**Background:** Carried on the Stretch list since early in the project,
same class of issue as `project-template`'s PT-008. CI has now run for a
full project cycle (PX-013 already caught and fixed one real Node.js 20
deprecation reactively — `actions/checkout@v4`→`v7`,
`hashicorp/setup-terraform@v3`→`v4`) — worth a deliberate audit instead
of continuing to bump versions only when GitHub forces the issue.

**Description:** Review every `uses:` line in
`.github/workflows/ci.yml` against its current latest stable major
version. Separately, decide and document a real trade-off this repo
hasn't named yet: tag-pinning (current, readable, mutable — a compromised
action could re-tag) vs. commit-SHA-pinning (immutable, the harder-nosed
supply-chain-security practice at real companies, less readable without
a comment). Lowest-risk item of the four requested — pure CI hygiene, no
live cluster interaction at all.

**Acceptance criteria:**
- [x] Every `uses:` line in `ci.yml` reviewed against current latest
      stable major version — both already current, no bump needed
- [x] Tag-pinning vs. SHA-pinning decision made and documented as a named
      trade-off, not a silent default
- [x] If SHA-pinning adopted, each pinned SHA has a comment noting which
      tag/version it corresponds to
- [x] CI still green after any version bumps — confirmed on the real
      PR run (#56), all 4 jobs pass

---

## PX-020 — Real Postgres backup story (WAL-E/WAL-G) via the Zalando operator

**Status:** DONE — closed out 2026-08-01 (PR #57, `63ef420`). Full
architecture, retention, and stated RPO documented in `docs/SPEC.md` §7.

**Verification, real evidence not assumed:**

- **Backup target:** in-cluster MinIO (`k8s/minio/`), pinned to `wk-2` —
  deliberately not `wk-1` (where Postgres runs), so a `wk-1` disk failure
  can't destroy both the live data and its only backup. Confirmed real
  headroom before deploying: `wk-2` had ~50GB disk free, ~6.4GB RAM
  available at the time.
- **Real platform issue #1, hit and fixed:** the Bitnami `minio` chart's
  images (`docker.io/bitnami/minio`) don't resolve at all — Broadcom
  moved Bitnami's free-tier images behind a paid registry mid-2025,
  confirmed directly (`ImagePullBackOff`, then a live Docker Hub API
  check returning zero tags). Switched to the official `minio/minio`
  chart (`quay.io/minio` images, unaffected). The old Bitnami
  `Deployment`'s `spec.selector` being immutable also blocked an in-place
  chart swap — deleted the (empty, zero-data) Deployment once and
  re-synced clean.
- **WAL-G continuous archiving:** configured via `spec.env` directly on
  `k8s/postgres-operator/postgresql-cr.yaml` (not a separate operator
  ConfigMap) — Spilo auto-set `archive_command` to
  `envdir "/run/etc/wal-e.d/env" wal-g wal-push "%p"` once the env vars
  landed, confirmed via `SHOW archive_command`. A forced `pg_switch_wal()`
  + `CHECKPOINT` produced a real WAL segment
  (`00000006000000000000003F.lz4`) confirmed via `mc ls` directly against
  MinIO — not `pg_stat_archiver` alone, and not operator/pod logs.
- **Real platform issue #2, hit and fixed:** every WAL push and base
  backup initially failed with `"Server side encryption specified but
  KMS is not configured"` — Spilo defaults `WALG_S3_SSE` to `AES256`
  whenever WAL-G is enabled, assuming a real S3 with SSE-S3/KMS. This
  MinIO has none. An empty `WALG_S3_SSE` value did **not** fix it
  (Spilo's `configure_spilo.py` treats any falsy value as "use the
  AES256 default") — found the actual dedicated flag,
  `WALG_DISABLE_S3_SSE=true`, by reading `configure_spilo.py` directly
  inside the running pod rather than guessing further. Fixed for real:
  re-tested WAL push and base backup both succeeded cleanly afterward.
- **Base backup:** triggered directly via Spilo's own script
  (`envdir "/run/etc/wal-e.d/env" /scripts/postgres_backup.sh` — the
  exact invocation the `BACKUP_SCHEDULE` cron uses internally), completed
  successfully (`base_000000060000000000000043`), confirmed via `mc ls`
  directly against MinIO — full `tar_partitions/` + a `backup_stop_sentinel.json`
  present, not assumed from the trigger command's exit code.
- **Restore, the step that actually matters:** seeded a real marker row
  in `app_db` on the *live* cluster, recorded its checksum
  (`04adfd945b63ec988bbc2d4dfc14cc13`). Used the operator's native
  `spec.clone` mechanism (`s3_wal_path`/`s3_endpoint`/credentials) to
  restore into a throwaway `postgresql` CR (`px020-restore-test`, applied
  directly, never committed to git) — confirmed via its own pod logs that
  it genuinely restored from the real base backup
  (`wal-g backup-fetch ... base_000000060000000000000043`), not a fresh
  empty bootstrap. Queried the restored scratch cluster: same marker row,
  same checksum, byte-for-byte identical. Scratch `postgresql` CR and its
  PVC deleted immediately after (operator auto-deleted the PVC; confirmed
  via `kubectl get pvc`, not assumed).
- **A stale-status anomaly caught and explained, not ignored:** after all
  of the above, the live `proxmox-iac-pg` CR's own status briefly read
  `UpdateFailed`. Traced it to a transient sync race during the pod's
  mid-restart promotion window (`"cannot execute ALTER ROLE in a
  read-only transaction"`, timestamped *before* the SSE fix even landed)
  — confirmed the live cluster was actually healthy throughout
  (`pg_is_in_recovery()` = false, marker data intact, 0 restarts on the
  current pod), then forced a reconcile (`kubectl annotate` nudge) and
  watched the status self-correct to `Running`. Documented rather than
  silently worked around, since a stale status field on a stateful
  service is exactly the kind of thing worth naming even when harmless.
- **Retention/schedule:** `BACKUP_SCHEDULE="0 3 * * *"` (daily 03:00
  UTC), `BACKUP_NUM_TO_RETAIN=3` — roughly a 3-day recovery window,
  Spilo's own script prunes older base backups + their now-unneeded WAL
  automatically. RPO stated honestly in `docs/SPEC.md` §7, including the
  real caveat: `archive_timeout` isn't set, so a near-idle database could
  see an unbounded worst-case gap between WAL shipments — named as a
  deferred refinement, not glossed over.

**Background:** `docs/PRD.md`'s non-goals section explicitly punted
"production-grade backup/DR for the databases" to a future item — today's
honest answer to "what happens if the Postgres PV is lost" is "data
loss." Deliberately sequenced before PX-022 (Longhorn): a real, tested
backup should exist *before* migrating the storage layer underneath the
same data, not after.

**Description:** The Zalando Postgres Operator has native continuous
WAL-G archiving to S3-compatible object storage plus periodic base
backups, configured via the operator's own CRD/ConfigMap fields
(`WAL_S3_BUCKET` etc.) — the real production pattern, not a bolted-on
`pg_dump` cron job. Needs an S3-compatible target; MinIO self-hosted
in-cluster is the natural fit for a home lab (no external dependency, no
cost, another real Helm-deployed component this project can defend) —
worth naming explicitly rather than assuming a real AWS bucket is
appropriate here.

**Decisions to make explicit before/during implementation:** backup
target (MinIO in-cluster recommended, or an alternative with stated
rationale); retention/schedule; and — the part that actually matters —
whether a real restore gets exercised, not just a backup file's
existence confirmed. An untested backup is not a backup.

**Acceptance criteria:**
- [x] Backup target decided and documented — in-cluster MinIO, `wk-2`
- [x] WAL-G continuous archiving configured via the operator, confirmed
      via a real WAL segment landing in the target
- [x] At least one full base backup completes, verified in the target
      directly, not assumed from operator logs
- [x] A real restore exercised end to end into a throwaway/scratch
      `postgresql` CR (not the live one) — data confirmed to match
      (checksum-verified), not just "restore exited 0"
- [x] `docs/SPEC.md` updated with the backup architecture, retention, and
      stated RPO (§7)

---

## PX-021 — MetalLB for a real LoadBalancer IP instead of NodePort

**Status:** DONE — closed out 2026-08-01.

**Verification, real evidence not assumed:**

- **IP allocated:** `192.168.10.13`, confirmed free three independent
  ways, same rigor as `.10`-`.12`/`.50`: ICMP ping (no response), ARP
  table (`INCOMPLETE`, no entry), and the router's own DHCP
  client/static-lease list — confirmed directly by igalhub, since this
  environment has no access to the router's admin interface.
- **MetalLB installed:** official chart (layer2 mode), first brand-new
  service installed directly through ArgoCD like PX-020's MinIO, not
  adopted from a pre-existing install. `controller` Deployment +
  `speaker` DaemonSet confirmed `Running` on all 3 nodes (cp-1/wk-1/
  wk-2) — `speaker` deliberately unpinned, needs cluster-wide presence
  to announce/fail over the VIP regardless of which node holds it.
  `IPAddressPool`/`L2Advertisement` applied as a *separate* ArgoCD
  Application, synced only after `metallb` itself was confirmed
  `Healthy` (MetalLB's own CRDs have to exist first) — confirmed via
  `kubectl get ipaddresspool`/`l2advertisement` directly, not assumed
  from the sync result alone.
- **nginx-ingress switched to `LoadBalancer`:** confirmed
  `EXTERNAL-IP: 192.168.10.13` picked up on the real Service, not just
  the manifest diff. Non-disruptive: controller pod's UID and restart
  count both confirmed identical before/after (a Service-type change
  doesn't touch the pod) — same discipline as every stateful/higher-risk
  change in this project even though this one was lower-risk by
  construction.
- **Every existing hosts-file-routed service re-verified via the new
  IP, no port number:** Grafana (`302`, its normal login redirect —
  not a regression), Jenkins (`/login` → `200`, matching the exact same
  response via the old NodePort path checked side-by-side), ArgoCD
  (`200`), landing page (`200`) — all through `192.168.10.13` directly
  with a `Host:` header, no `:30963` needed.
- **`docs/SPEC.md` updated:** §4 (new ingress-entry-point paragraph,
  NodePort noted as prior state, not removed — kept functional as a
  fallback since a `LoadBalancer` Service still allocates NodePorts by
  default) and §8/§9 (build-order stretch item and the previously-open
  MetalLB-vs-NodePort question, both resolved). `k8s/README.md` gained
  matching "What's installed" entries for PX-020 (a real gap left over
  from that ticket, caught and fixed here) and PX-021.

**Background:** nginx-ingress currently runs as a NodePort Service —
every service behind it (Grafana, Jenkins, ArgoCD, the landing page) is
reached via a randomly-assigned high port (`30963`/`31395`) that has to
be looked up with `kubectl get svc` rather than a predictable address.
`docs/SPEC.md` §8 already flags MetalLB as the stretch alternative to
NodePort.

**Description:** Deploy MetalLB in layer2 mode — the only mode that
makes sense on a single flat home-lab bridge; BGP mode needs router
support this network doesn't have. Configure an address pool carved out
of the same structurally-DHCP-excluded range already established for the
VMs' static IPs (`docs/SPEC.md` §4's pool-narrowing pattern extends
naturally to one more address). Switch nginx-ingress's Service from
`NodePort` to `LoadBalancer` so it gets a real, dedicated IP.

**Decisions to make explicit:** which IP to allocate (must be confirmed
structurally excluded from DHCP the same three independent ways §4 used
for `.10`-`.12`/`.50`, not just observed-empty); whether hosts-file
entries then point at that one dedicated IP directly instead of a node
IP + NodePort, simplifying every ingress-routed service at once.

**Acceptance criteria:**
- [x] New static IP allocated for MetalLB's pool, confirmed excluded from
      DHCP the same rigorous way as the existing VM IPs
- [x] MetalLB installed (layer2 mode), address pool configured
- [x] nginx-ingress Service switched to `type: LoadBalancer`, confirmed
      it picks up the allocated IP
- [x] Every existing hosts-file-routed service (Grafana/Jenkins/ArgoCD/
      landing page) re-verified reachable via the new IP with no port
      number needed
- [x] `docs/SPEC.md` §4/§8 updated to reflect MetalLB as the real ingress
      entry point, NodePort noted as the prior state

---

## PX-022 — Longhorn distributed storage, replacing local-path for Postgres/Redis PVs

**Status:** DONE — closed out 2026-08-01. Longhorn installed, Redis and
Postgres both migrated and independently verified, and the Git/ArgoCD
drift this migration created (the whole cutover happened via raw
`kubectl`, bypassing Git) fixed and merged in this same PR — acceptance
criteria only checked off once that fix actually landed, not before.

**Progress so far, real evidence not assumed:**

- **Disk headroom confirmed live**, not assumed from the RAM budget:
  wk-1 47GB free (19% used), wk-2 50GB free (14% used), both single-disk
  VMs (no separate dedicated disk — Longhorn uses a directory on the
  existing root filesystem). cp-1 excluded entirely (34GB free but
  deliberately workload-free per `docs/SPEC.md` §1) — only 2 real
  storage-candidate nodes exist.
- **Replication factor 2**, justified against those real numbers: a 3rd
  replica would have nowhere valid to go (cp-1 isn't meant to host
  workloads); total data in scope (Postgres 2Gi + Redis 2x1Gi ≈ 4Gi)
  costs ~8Gi at factor 2, comfortably under 10% of either node's free
  space.
- **Longhorn installed** (official chart v1.12.0) directly through
  ArgoCD — another brand-new service since PX-015, not an adoption.
  Storage restricted to wk-1/wk-2 via a `longhorn-storage=true` node
  label (applied live via `kubectl label`, not yet codified in
  Ansible — a known gap, noted so a fresh node rebuild doesn't silently
  lose it). `longhorn` StorageClass created separately (after the chart
  Application was confirmed `Healthy` — its CRDs have to exist first),
  `numberOfReplicas: 2` confirmed directly on the real object.
- **A real platform issue hit and fixed:** the first sync hung
  indefinitely — `longhorn-pre-upgrade` hook Job stuck `Running`,
  blocking everything else, because it referenced a ServiceAccount that
  only the chart's *normal* (non-hook) resources create, which ArgoCD
  hadn't applied yet since the blocking PreSync hook came first. Root
  cause: ArgoCD translates every Helm hook type — including
  `pre-upgrade` — into its own PreSync hook and runs it regardless of
  whether this is genuinely a fresh install (unlike native
  `helm install`, which skips pre-upgrade hooks on install). The chart's
  own `values.yaml` documents this exact gotcha —
  `preUpgradeChecker.jobEnabled: true` → `false` fixed it for real,
  confirmed via a clean re-sync (`Synced`/`Succeeded`, all CRDs
  `Established: true`).
- **Longhorn functionally verified** before touching real data: a
  throwaway PVC/pod smoke test confirmed exactly 2 replicas landing on
  wk-1 and wk-2, `ROBUSTNESS: healthy`, and clean provision→delete
  lifecycle (volume fully reaped after PVC deletion, `reclaimPolicy:
  Delete` working as expected).
- **Redis migrated first, both PVCs, fully verified and cut over.**
  Copied `/data` (AOF persistence, not RDB) from both old local-path
  PVCs to new Longhorn PVCs via a temporary pod mounting all four
  volumes simultaneously (old PVCs read-only) — every file's `md5sum`
  matched exactly, ownership/permissions preserved. Functionally
  verified beyond file checksums: booted a temporary standalone Redis
  pointed at the copied master data, it loaded the AOF cleanly (`Ready
  to accept connections`), and `DBSIZE`/`GET px009-check` matched the
  live source exactly (`1` / `"ok"`).

  **Cutover executed by igalhub directly, not by Claude Code** — the
  Bitnami chart hardcodes its PVC name and the old PVCs have
  `reclaimPolicy: Delete`, so freeing the name for reuse is the same
  action as deleting the old data; per this repo's hard rule on
  permanently destructive actions, the exact command sequence (scale
  down → retain+release the verified Longhorn PVs → delete the old
  local-path PVCs → statically rebind new PVCs under the original names
  → scale back up) was written out, reviewed, and run by igalhub
  himself. **Independently re-verified by Claude Code after, not taken
  on report alone:** both pods `Running` with 0 restarts (fresh pods on
  the new PVCs), both PVCs `Bound` with `storageClassName: longhorn`,
  both underlying PVs `Bound`/`Retain`, `GET px009-check` → `"ok"`,
  `DBSIZE` → `1`, and each volume confirmed via
  `kubectl get replicas.longhorn.io` to genuinely have exactly 2
  replicas split across wk-1 and wk-2 — not assumed from the StorageClass
  parameter alone.

**Postgres migration, real evidence not assumed:**

- **Fresh base backup taken immediately before cutover** (belt-and-
  suspenders alongside PX-020's standing continuous archiving) —
  `base_00000006000000000000004C`, confirmed landed in MinIO directly
  via `mc ls` (not just the trigger command's output), not the earlier
  verification-pass backup — explicitly re-taken so the actual cutover
  never relied on WAL-G's fallback-to-latest-available behavior.
- **Verified via a throwaway clone before ever touching the live
  cluster:** used the operator's native `spec.clone` mechanism (the
  same one PX-020 proved out for its restore test) to spin up
  `px022-pg-lh-verify` — a separate CR, `storageClass: longhorn`,
  cloning from that exact fresh backup. Its own pod logs confirmed a
  real restore (`wal-g backup-fetch ... base_00000006000000000000004C`),
  not a blank bootstrap. Checksum of the live marker row
  (`04adfd945b63ec988bbc2d4dfc14cc13`) matched exactly, 2 Longhorn
  replicas confirmed split across wk-1/wk-2. Deleted this verification
  clone myself afterward — safe, since it was a throwaway resource I
  created, not the original data.
- **CR-identity-preserving cutover, not a rename:** Postgres's identity
  (Service DNS, Patroni leader-election key, credential Secret names)
  lives entirely at the CR level, unlike Redis's raw-PVC-name collision.
  The cutover deleted the old `proxmox-iac-pg` CR (which — same
  category as Redis's old-PVC deletion — also deletes its StatefulSet,
  its `local-path` PVC under `reclaimPolicy: Delete`, and its credential
  Secrets) and recreated a CR under the *exact same name*,
  `storageClass: longhorn`, cloning from the fresh backup — reclaiming
  the identity so nothing else in the cluster needed to change. Per this
  repo's hard rule on permanently destructive actions, this was not run
  by Claude Code — the exact command sequence was written out, reviewed
  inline in chat, and executed by igalhub himself.
- **Independently re-verified after, not taken on report alone:** pod
  `Running`, PVC `Bound` on `storageClassName: longhorn`, the same
  marker row present, and `SHOW archive_command` confirming WAL-G
  continuous archiving survived onto the new cluster
  (`envdir "/run/etc/wal-e.d/env" wal-g wal-push "%p"`, unchanged from
  before the cutover) — the backup story from PX-020 wasn't lost in the
  migration.

**Git/ArgoCD drift fixed, same PR:** the entire cutover for both
services happened via raw `kubectl`, bypassing Git entirely — a real gap
worth naming, not glossed over. `k8s/postgres-operator/postgresql-cr.yaml`
updated to `spec.volume.storageClass: longhorn` (matching live state),
deliberately *without* the `spec.clone` block — that block only ever
mattered for the one-time bootstrap, and the live CR's copy of it (which
held a real, plaintext MinIO credential in `s3_secret_access_key`) was
removed from the live cluster too via a fresh `kubectl apply` of the
corrected manifest, confirmed via a direct annotation check that the
credential no longer appears in `last-applied-configuration`. Also
caught the same kind of drift in `k8s/redis/values.yaml` — its
`persistence.storageClass` was never set (defaulted to the cluster's
default class, still `local-path`), which would have silently reverted
any future PVC recreation back to `local-path` despite the live PVCs
already running on Longhorn; both `master`/`replica` blocks now declare
`storageClass: longhorn` explicitly. `git diff` reviewed before
committing — confirmed no secret material anywhere in either file's
diff, same discipline as PX-018.

**A real (non-cosmetic) gap found and fixed while pre-merge-testing the
Redis fix, not left as permanent drift:** syncing the corrected
`k8s/redis/values.yaml` against the live cluster failed —
`StatefulSet.apps "redis-master/replicas" is invalid: ... updates to
statefulset spec for fields other than 'replicas', 'ordinals',
'template', ... are forbidden` — `volumeClaimTemplates` is immutable on
an existing StatefulSet in Kubernetes, confirmed via a real sync attempt
(safe: the API server rejects the patch outright, nothing was touched —
both pods' UID and restart count confirmed identical before/after).
Left unfixed, this wasn't just cosmetic `OutOfSync` noise: any future
scale-up of either StatefulSet would have silently created a new
replica's PVC on `local-path`, not `longhorn`, since the template field
was frozen at its original (unset) value forever. Fixed for real via
`kubectl delete statefulset redis-master redis-replicas --cascade=orphan`
(removes only the StatefulSet controller objects, not the pods or PVCs)
followed by a clean ArgoCD re-sync, which recreated both StatefulSets
with the correct template and adopted the existing pods/PVCs without
touching any data. Verified: `volumeClaimTemplates[0].spec.storageClassName`
now genuinely `longhorn` on both, both pods' UID and restart count
(`0`) identical throughout, data confirmed intact (`GET px009-check` →
`"ok"`).

**`docs/SPEC.md` updated** (§5 rewritten with the real storage
architecture, disk budget, and replication-factor rationale; the top
status header and §8's build-order item 9 both updated to reflect
PX-022 as done, not in-progress).

**Background:** Postgres and Redis PVs currently use k3s's default
`local-path` storage class — each PV's actual data lives on a single
node's local disk, unreplicated. If wk-1 (hosting both) suffers a disk
failure, that data is gone regardless of ArgoCD/Git-tracked config being
intact, since `Application` manifests describe desired state, not the
bytes on disk. Highest-risk item of the four requested here — touches
live, real data on both stateful services adopted into ArgoCD under
PX-015 — deliberately sequenced last, and only after PX-020's real,
tested Postgres backup exists as a safety net.

**Description:** Install Longhorn via its own Helm chart, which needs
local disk space earmarked on at least 2-3 nodes for its own replica
storage (separate from the VMs' existing disks — needs a real disk-space
check against the actual nodes, `docs/SPEC.md` §3 has never had a *disk*
budget conversation, only RAM/vCPU). Create a `longhorn` StorageClass
with a replication factor matched to real available disk headroom.
Existing PVCs can't be swapped to a new StorageClass in place — this is
an explicit per-volume migration (provision a new Longhorn-backed PVC,
copy data across, cut over, verify, only then decommission the old PV),
not a config change, verified with the same pod-identity/data-integrity
discipline established across PX-015 (checksums, not just "the pod
started").

**Decisions to make explicit:** replication factor (2 vs. 3, against
actual measured disk headroom); migration order — Redis first (already
established in PX-015 as low real-risk, no dependents) to prove the
migration mechanics before touching Postgres; whether to take one more
fresh Postgres backup immediately before its own cutover, as a second
safety net beyond PX-020's standing backup story.

**Acceptance criteria:**
- [x] Disk headroom confirmed on nodes that will host Longhorn replicas
      (real `df -h`/`lsblk`, not assumed from the RAM budget)
- [x] Longhorn installed, StorageClass created with an explicit,
      justified replication factor
- [x] Redis migrated first (both PVCs), verified via checksum/data
      comparison before its old PV is decommissioned, not just pod health
- [x] A fresh Postgres backup taken and confirmed immediately before its
      migration (belt-and-suspenders alongside PX-020)
- [x] Postgres migrated, verified via checksum/data comparison plus a
      real query against known data, before its old PV is decommissioned
- [x] Old `local-path` PVs deleted only after both migrations are
      independently confirmed — not left dangling, not deleted
      prematurely
- [x] `docs/SPEC.md` updated: storage architecture, replication factor
      and its rationale, disk budget

---

## PX-023 — Enable VM ballooning; PX-016's memory-gauge fix was incomplete

**Status:** DONE — closed out 2026-08-01 (PR #63, `18d2e50`). All
acceptance criteria met with real evidence: `terraform plan`/`apply`
confirmed scoped to only `memory.floating`; all 3 nodes rebooted and
confirmed `balloon` live in `qm config`; a process deviation (wk-1/wk-2
rebooted implicitly during `apply`, not via the planned per-VM
go-ahead) caught, investigated, and documented rather than glossed over,
with Longhorn/Postgres/Redis health independently reconfirmed clean
afterward; gauge monitored stable across a multi-hour post-reboot window
(~2h and ~3h13m checks), tracking real `kubectl top nodes` usage both
times — the specific verification gap that closed PX-016 prematurely.
PX-007 and PX-016 both given correction addenda tying the full
three-ticket root-cause chain together. CI green (ansible-lint/ruff/
shellcheck/terraform), merged via `gh pr merge --squash --delete-branch`,
branch cleaned up locally + on origin.

**Correction (2026-08-01, found by igalhub reporting Jenkins 503s hours
after close-out) — the stateful-service health check had a real gap:**
`jenkins-0` was crash-looping on its init container the entire time
since this ticket's implicit wk-2 reboot, undetected until igalhub hit
`http://jenkins.lab.test:30963/job/proxmox-iac-ci/` directly and saw a
503. Root cause, confirmed via the init container's own logs, not
guessed: the exact same bug PX-016 already documented — the plugin-copy
`cp` (no `-f`) in the init container choking on pre-existing files in
the `emptyDir` that survived the *graceful* reboot, interactive
overwrite prompts hitting instant EOF, exit 1, crash loop. Event
timeline confirmed the trigger directly: first failure timestamped at
wk-2's implicit reboot during this ticket's `terraform apply`
(`~19:13` IDT), not something unrelated.

**Why this slipped through this ticket's own verification, stated
plainly:** the post-reboot stateful-service health check performed
above was explicitly scoped to Longhorn/Postgres/Redis — the services
PX-022 introduced — and never extended to Jenkins on the same node,
even though PX-016 had already put this exact failure mode on record as
a known risk of *any* wk-2 reboot, planned or implicit. The check that
would have caught it was already written down in a prior ticket and
simply wasn't run against this reboot. No data was at risk (Jenkins's
build history lives on its own PVC, confirmed intact — all 45 prior
builds present, `nextBuildNumber` consistent), but the gap in
verification coverage is the real finding here, not the crash itself.

**Fixed, verified, not just "pod looks fine":** `kubectl delete pod
jenkins-0` (StatefulSet recreated it fresh, clean `emptyDir` — same
non-destructive fix as PX-016). Confirmed `2/2 Running`, `0` restarts;
`/login` returns `HTTP 200` through both the real LoadBalancer IP
(`192.168.10.13`) and the NodePort igalhub originally hit; all 45 prior
builds confirmed present on disk (`nextBuildNumber: 46`, directories `1`
through `45` all present — an initial `ls`-sort misread briefly looked
like data loss and was corrected immediately, not left uncorrected).

**Lesson for future tickets that reboot (or cause an implicit reboot
of) wk-2:** the Jenkins init-container crash-loop is a known, recurring
risk of *any* wk-2 reboot, not a one-off — it should be a standard check
alongside whatever service actually motivated the reboot, the same way
this ticket already learned to check Longhorn/Postgres/Redis after
touching wk-1. A reboot's blast-radius check needs to cover every
stateful/quasi-stateful thing on the node that reboots, not just the
one this particular ticket happens to be about.

**Background:** During PX-022, igalhub reported the Proxmox memory gauge
maxed out again on wk-1/wk-2 — the same symptom PX-016 closed out as
DONE. Investigation found PX-016's conclusion was wrong, or at least
incomplete: the guest agent has been running continuously without
interruption since PX-016's reboot (`systemctl status
qemu-guest-agent`: `active (running)` for 8h+, zero restarts), so this
isn't the "agent not negotiated at boot" cause again. Real cause: all
three VMs have `balloon: 0` in `terraform/vms.tf` (ballooning explicitly
disabled). Inside wk-1 right now: `free -h` shows `used: 2.1Gi`,
`buff/cache: 5.8Gi`, `available: 5.6Gi` — completely healthy Linux
behavior (spare RAM used for reclaimable disk cache, by design).
Without ballooning enabled, Proxmox can't get real memory-pressure stats
from the guest and falls back to something close to `total - free`,
which trends toward ~100% on *any* healthy long-running Linux guest,
since Linux deliberately keeps `free` near zero. PX-016's reboot never
fixed the actual cause — it only reset the page cache to empty, so the
gauge looked accurate for a few hours until cache filled back up again,
exactly as it has now. This was step 4 in PX-016's own original plan
("if inconclusive: try enabling the balloon device via Terraform") —
never reached, because the reboot appeared to work at the time.

**Description:** Set a real, non-zero `balloon` value in
`terraform/vms.tf` for cp-1/wk-1/wk-2 (replacing the current `balloon:
0`), confirm via `terraform plan` exactly what this changes, apply, and
reboot each VM (same disruptive-action discipline as PX-016: confirm no
in-progress work first, one VM at a time, explicit go-ahead before each
reboot). After reboot, monitor the gauge over a longer window than
PX-016 did (hours, not minutes) to confirm it actually stays accurate as
the page cache fills back up — not just accurate immediately
post-reboot, which is exactly the false signal that closed PX-016
prematurely.

**Implementation decision — per-VM floor values:** `memory.floating` set
to 75% of dedicated for wk-1/wk-2 (6144 of 8192, 2048 MB reclaimable)
and a tighter 87.5% for cp-1 (3584 of 4096, 512 MB reclaimable). cp-1's
tighter floor rests on three independent points, verified against
current cluster state, not assumed: it's the sole control-plane with no
HA; it runs etcd, whose loss under reclaim pressure is categorically
worse and less recoverable than a worker losing a scheduled pod; and it
has half the absolute memory of a worker to begin with, so the same
percentage floor would already leave it less reclaimable headroom before
any of the above. (An earlier draft of this justification also cited
cp-1 running ArgoCD and Longhorn's control-plane components — checked
against `docs/SPEC.md` and PX-022 and found false: ArgoCD is on wk-1,
Longhorn is explicitly restricted to wk-1/wk-2, and cp-1's
`node-role.kubernetes.io/control-plane:NoSchedule` taint, re-verified
live in PX-016, keeps both off it. That claim is dropped; the three
points above stand on their own and don't depend on it.)

**Process deviation — wk-1/wk-2 rebooted without a discrete go-ahead:**
`terraform apply` (`0 added, 3 changed, 0 destroyed`, matching the
reviewed plan exactly) did not just update `qm config` — the bpg/proxmox
provider triggered an *implicit in-place reboot* of wk-1 and wk-2 as
part of applying `memory.floating`, evidenced by apply duration alone:
cp-1's `memory` block update completed in 17s, wk-1/wk-2's each took
1m45s — consistent with a full guest reboot, not a hot-applied config
write. Confirmed directly via `uptime -s` on each VM post-apply: wk-1
and wk-2 both showed a fresh boot at `2026-08-01 16:13:04`, inside the
apply's own execution window, well before cp-1's separate, deliberate,
explicitly-authorized `sudo reboot` at `16:14:24`. This was caught only
by checking `uptime` after the fact, not predicted beforehand.

At the time, the go-ahead given was for `terraform apply` — the config
change — not framed as also authorizing a reboot of wk-1/wk-2. The
ticket's own plan calls for one VM at a time, explicit go-ahead
*specifically for each reboot*, with an idle/in-progress-work check
immediately before each one; that check never got a chance to run for
wk-1/wk-2 before they went down, since nobody knew a reboot was
imminent. In substance a real reboot did occur on all three nodes (the
actual mechanism this ticket needs), but the planned one-at-a-time
sequencing was not what actually happened for two of the three — this
is recorded as a real deviation, not retroactively treated as
equivalent to the planned process.

Post-hoc mitigation taken once discovered: full stateful-service health
check run against wk-1/wk-2 (which host Postgres/Redis/Longhorn,
PX-022) — Longhorn volumes/replicas (`attached`/`healthy`/`running`,
correct 2× split, ages unchanged, no rebuild triggered), Postgres pod
(0 restarts) and its marker row (`created_at` predates the reboot,
untouched), Redis pods (0 restarts) and its `px009-check` key (`ok`)
plus live replication (`state=online`, `lag=0`) all confirmed clean. No
data loss or corruption resulted, but that's a fortunate outcome
verified after the fact, not something the process was designed to
guarantee in advance.

**Lesson for future tickets:** changing `memory.floating` (and
potentially other hardware-affecting VM attributes) via the bpg/proxmox
provider can trigger an implicit reboot at `apply` time, not just a live
config write. For this class of Terraform change, the explicit,
per-VM, "confirm nothing in-progress first" go-ahead needs to happen
**before `terraform apply` itself**, not before a separately-scheduled
`reboot` command — by the time apply finishes, the reboot may have
already happened. Check `terraform plan`'s output and, if unclear
whether an attribute is hot-reconfigurable, assume it may force a reboot
and gate approval accordingly.

**Acceptance criteria:**
- [x] `terraform plan` reviewed before apply — confirmed only the
      `balloon` (`memory.floating`) value changed, nothing else
- [x] All three VMs rebooted — cp-1 with explicit go-ahead immediately
      before its reboot, same idle/in-progress-work check as PX-016;
      wk-1/wk-2 rebooted via an *unintended path* (implicit reboot
      during `terraform apply`, not a separately-authorized reboot
      command) — see process-deviation note above. Satisfied in
      substance (a real reboot occurred on all three), explicitly not
      equivalent to the planned one-at-a-time process for wk-1/wk-2.
- [x] Memory gauge monitored over an extended window (hours) post-reboot
      to confirm it stays accurate as page cache fills — the actual gap
      in PX-016's original verification. Checked twice, ~2 hours apart
      (`~2h` and `~3h13m` post-reboot uptime): cp-1 56.0%→55.5%,
      wk-1 51.0%→51.7%, wk-2 35.0%→35.9% — flat, no drift toward 100%,
      and closely tracking real `kubectl top nodes` usage both times
      (cp-1 43-44%, wk-1 50-51%, wk-2 32-34%). This is the specific
      window PX-016 never checked — its false "fixed" reading held for
      "a few hours" before silently drifting back; here the same
      multi-hour window was explicitly re-checked and held stable.
- [x] `docs/TICKETS.md` PX-016 gets a correction note pointing here,
      since its DONE status/root-cause conclusion turned out to be
      incomplete — history isn't rewritten, but not left misleading
      either. Already present (dated 2026-08-01, written when this
      ticket was originally drafted) — verified accurate against what
      actually shipped, not just present. PX-007 also given a forward-
      pointing addendum for the same reason (see below) — its own
      correction note predates PX-016/PX-023 and stopped at "leading
      theory," never confirmed.
- [x] `docs/SPEC.md` updated if the resource-budget section needs a note
      about ballooning being enabled — checked, not needed: §3's cp-1
      role line was suspected stale mid-ticket (an earlier draft
      justification claimed cp-1 now runs ArgoCD/Longhorn control-plane
      components) but that claim was verified false against `SPEC.md`
      itself and PX-022 — the line was already accurate and left
      untouched. No resource-budget change resulted from enabling
      ballooning (dedicated memory unchanged, only the reclaim floor
      added), so no note was needed there either.

**Root-cause chain across three tickets, for anyone landing on any one
of them:** PX-007 fixed "Proxmox has no guest memory data at all"
(missing `qemu-guest-agent`). PX-016 fixed "the gauge looks right for a
few hours, then drifts back to ~100%" — actually just a page-cache reset
from a reboot masking the real problem, not a fix. This ticket (PX-023)
fixes the actual mechanism: without a non-zero `balloon`/`memory.floating`
value, Proxmox has no real memory-pressure telemetry from the guest and
falls back to something close to `total - free`, which trends toward
100% on *any* healthy long-running Linux guest since Linux deliberately
keeps `free` near zero (spare RAM used for reclaimable disk cache, by
design). Enabling ballooning gives Proxmox the actual purpose-built
mechanism for this — verified stable over a multi-hour window above, not
just immediately post-reboot.

---

## PX-024 — Rotate the MinIO backup-admin credential

**Status:** DONE — closed out 2026-08-01 (PR #66, `2561a97`).
Independently re-verified before flipping status (not trusted from the
implementation PR's own report alone): both MinIO and the Postgres pod
still `1/1 Running`/`0` restarts several minutes after their rotation
restarts, continuous WAL archiving still landing new segments in MinIO
under the new credential. Decision made: **rotate**, not accept-as-is —
`backup-admin` is
confirmed the literal MinIO *root* credential (`rootUser`, verified live
via `kubectl get secret minio-auth -o jsonpath='{.data.rootUser}'`), not
a scoped least-privilege user, so a leak has full blast radius against
the only backup store this project has. That raised the stakes enough
to justify rotation despite MinIO being internal-only and the exposure
vectors themselves being narrow (etcd/audit-log history, a chat
transcript — neither reachable by mere network access).

**Background:** Found during PX-022's verification, filed separately —
same "found during verification of ticket X, filed separately as its
own ticket" pattern as PX-018. The MinIO `backup-admin` root credential
(created in PX-020, reused directly for WAL-G's S3 access rather than a
dedicated least-privilege user — a stated trade-off at the time, see
PX-020) ended up more exposed than originally scoped:

- It's sitting in plaintext inside the `postgresql` CR's
  `kubectl.kubernetes.io/last-applied-configuration` annotation, from
  the one-time `spec.clone` bootstrap step used during PX-022's Postgres
  migration — readable indefinitely by anyone with `get` on that
  resource. (PX-022 already removed the `clone` block itself from the
  live CR spec and its current annotation, but the credential was
  present in that annotation's history for the duration of the
  migration.)
- It was also displayed directly in a chat transcript during this
  session (the migration commands were reviewed inline before running),
  which is a separate exposure surface from the cluster-internal one
  above.

**Decision to make, not just an automatic action:** whether the real
risk here (internal-only service, no external exposure, no evidence of
any other consumer of this credential) justifies rotation effort, or
whether documenting the exposure and moving on is the more proportionate
call. If rotating: generate a new MinIO root credential, update the
sealed secrets in both `k8s/minio/minio-auth-sealedsecret.yaml` and
`k8s/postgres-operator/postgres-backup-creds-sealedsecret.yaml` (kept in
sync per PX-020's design — same credential, two namespaces), confirm
WAL-G archiving/backups still work with the new credential before
considering the old one retired.

**Pre-rotation verification, not assumed:** confirmed `minio-auth` and
`postgres-backup-creds` are genuinely the only two consumers of this
credential — both a repo-wide grep (`grep -rn "backup-admin\|minio-auth\|
postgres-backup-creds"`, matches only in the two secrets' own files, the
MinIO chart's `values.yaml` `existingSecret` reference, and docs) and a
live-cluster check (every pod's spec across all namespaces scanned for a
reference to either secret name — only the `minio` pod and
`proxmox-iac-pg-0` matched). Rollback path confirmed technically sound
before touching anything: MinIO's root credential is mounted purely as a
Secret volume, read fresh at container start — not baked into on-disk
state — and bucket data lives on a separate PVC entirely independent of
which credential is configured, so reverting the SealedSecret to its
prior committed value and restarting again would have been a clean,
data-safe fallback had the new credential not come up cleanly (it did;
rollback wasn't needed).

**Rotation performed (2026-08-01):** new random `rootPassword`/
`AWS_SECRET_ACCESS_KEY` generated (`rootUser`/`AWS_ACCESS_KEY_ID` kept as
`backup-admin` — only the secret material needed to change to invalidate
what was exposed). Both secrets re-sealed via `kubeseal` against the
live controller's cert (versions confirmed matching, `0.38.4`), applied
directly via `kubectl apply` (confirmed neither is ArgoCD-managed — the
`minio` Application only sources the Helm chart/values, not this
secret). MinIO restarted first (`kubectl rollout restart
deployment/minio`, rolled out cleanly), Postgres pod restarted
immediately after (`kubectl delete pod proxmox-iac-pg-0`, StatefulSet
recreated it fresh, same non-destructive pattern as PX-016's
`jenkins-0`) — flagged and accepted the real, brief window between the
two restarts where WAL-G would fail to authenticate with the
now-invalid old credential (archive_command just retries, no data loss;
in practice the gap was well under a minute).

**Verified, not assumed:**
- Postgres pod `1/1 Running`, `0` restarts, `pg_is_in_recovery()` =
  `false`, marker row (`px020-restore-verification-2026-07-31`) intact
  and unchanged — data untouched by the rotation.
- New WAL segments confirmed landing in MinIO under the new credential
  within ~50s of the pod restart completing (continuous archiving
  resumed working, not just assumed from the pod being `Running`).
- A real base backup explicitly triggered via Spilo's own script (the
  exact cron invocation, `envdir "/run/etc/wal-e.d/env"
  /scripts/postgres_backup.sh`, not a bare re-run that skips the S3 env)
  — succeeded, `base_0000000A0000000000000083`, confirmed landing
  directly via `mc ls`/`mc find` against MinIO (not the script's exit
  code alone).
- Every pre-rotation base backup (2026-07-31 through earlier
  2026-08-01) confirmed still present and listable with the new
  credential — data survived the rotation intact, old backups not lost
  or orphaned.
- New credential authenticated successfully via `mc alias set` +
  `mc ls` directly against MinIO, independent of the Postgres path.

**Acceptance criteria:**
- [x] Explicit decision made and documented: rotate, or accept the risk
      as-is with reasoning — not left silently unresolved
- [x] If rotating: both sealed secrets updated with a new credential,
      confirmed in sync
- [x] If rotating: a real WAL segment and a real base backup both
      reconfirmed landing in MinIO with the new credential, same rigor
      as PX-020's original verification — not assumed to still work
- [x] `docs/TICKETS.md` PX-020 (or this ticket) notes the rotation for
      the record — recorded here, in this ticket

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
| PX-015 | ArgoCD retrofit | DONE |
| PX-016 | Resolve Proxmox memory-gauge inaccuracy (wk-1/wk-2/cp-1) | DONE |
| PX-017 | Narrow ghcr.io push token scope once repo is public | OPEN |
| PX-018 | Stop relying on a personal global gitignore for `*.tfvars` | DONE |
| PX-019 | CI Action version pinning audit | DONE |
| PX-020 | Real Postgres backup story (WAL-E/WAL-G) | DONE |
| PX-021 | MetalLB for a real LoadBalancer IP instead of NodePort | DONE |
| PX-022 | Longhorn distributed storage (Postgres/Redis PVs) | DONE |
| PX-023 | Enable VM ballooning; PX-016's memory-gauge fix was incomplete | DONE |
| PX-024 | Rotate the MinIO backup-admin credential | DONE |

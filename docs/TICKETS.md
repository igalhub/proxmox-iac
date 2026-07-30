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

**Status:** DONE (script) / awaiting execution

**Description:**
`scripts/build-cloud-init-template.sh` — downloads the Ubuntu 24.04 cloud
image, `qm create`/`qm importdisk`/`qm set` (cloud-init drive, boot order,
serial console, guest agent), `qm resize`, `qm template`. Deliberately
does not set `ciuser`/`sshkey` on the template — per-VM identity is
Terraform's job at clone time.

**Acceptance criteria:**
- [ ] Igal has run the script on `192.168.10.50`
- [ ] Template VMID 9000 confirmed present in the Proxmox UI, marked as
      template (not a regular VM)

---

## PX-004 — Terraform module skeleton

**Status:** OPEN

**Description:**
`terraform/` with `providers.tf` (bpg/proxmox), `variables.tf`,
`outputs.tf`. No VM resources yet — just the module wired up and
authenticating against the Proxmox API.

**Acceptance criteria:**
- [ ] `terraform init` succeeds
- [ ] `terraform plan` runs cleanly against the real Proxmox host with zero
      resources defined yet (proves API auth works before adding VMs)

---

## PX-005 — Terraform VM resource definitions

**Status:** OPEN

**Description:**
VM resources for cp-1/wk-1/wk-2, cloned from the PX-003 template, with
per-VM cloud-init config (hostname, static IP, SSH key) and sizing per
`docs/SPEC.md` §3 resource budget.

**Acceptance criteria:**
- [ ] `terraform apply` produces 3 VMs matching the SPEC.md sizing table
- [ ] All 3 VMs are SSH-reachable at their planned static IPs with no
      manual intervention after `apply`

---

## PX-006 — Terraform state decision

**Status:** OPEN

**Description:**
Decide and document (in `docs/SPEC.md`) local state file vs. a
self-managed remote backend. Home-lab single-operator project, so local
state may be the pragmatic answer — but the trade-off (no state locking,
no backup) needs to be a stated decision, not a default.

**Acceptance criteria:**
- [ ] Decision recorded in `docs/SPEC.md` with rationale
- [ ] If local: `.gitignore` confirmed to exclude `*.tfstate*`
      (already does — verify it's actually being honored)

---

## PX-007 — Ansible inventory + roles skeleton

**Status:** OPEN

**Description:**
`ansible/inventory` (static, matching Terraform outputs), `ansible.cfg`,
role skeletons: common/hardening, k3s-server, k3s-agent. Resolve whether
a separate containerd role is needed or if k3s's embedded containerd
makes that redundant (see SPEC.md build order note) before writing it.

**Acceptance criteria:**
- [ ] `ansible-lint` passes on all roles
- [ ] `ansible-playbook --check` runs without errors against the 3 real VMs

---

## PX-008 — k3s cluster bring-up

**Status:** OPEN

**Description:**
k3s-server role installs on cp-1 with `--disable=traefik`, captures join
token; k3s-agent role installs on wk-1/wk-2 and joins using that token.

**Acceptance criteria:**
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

**Status:** DONE

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
- [ ] `.claude/dev-check.sh` — write was blocked in-session (`.claude/` is
      a protected path this session can't write to); script delivered to
      Igal separately, needs manual copy into `.claude/dev-check.sh` +
      `chmod +x`

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
| PX-003 | Cloud-init template on Proxmox | Script DONE, execution pending |
| PX-004 | Terraform module skeleton | OPEN |
| PX-005 | Terraform VM resource definitions | OPEN |
| PX-006 | Terraform state decision | OPEN |
| PX-007 | Ansible inventory + roles skeleton | OPEN |
| PX-008 | k3s cluster bring-up | OPEN |
| PX-009 | Core services (ingress/Redis/Postgres/Sealed Secrets) | OPEN |
| PX-010 | Observability extension | OPEN |
| PX-011 | Reconcile scaffold against real project-template | DONE (dev-check.sh copy pending) |

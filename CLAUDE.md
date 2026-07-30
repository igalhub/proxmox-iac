# CLAUDE.md — working agreement for this repo

Project-specific instructions. Read this at the start of every session
before doing anything else.

> Reconciled 2026-07-30 against the real `igalhub/project-template`
> (previously inaccessible in-session, hence a hand-built stand-in — see
> `docs/TICKETS.md` PX-011). This repo is infra-as-code (Terraform/Ansible),
> not the template's Python/uv default, so it follows the template's
> `--lang bash` shape (shellcheck, plain git pre-commit hook, no
> pre-commit-framework/uv dependency) plus Terraform/Ansible-specific
> tooling the template itself has no opinion on.

---

## Project Overview

Home-lab Kubernetes cluster (k3s: 1 control-plane + 2 workers) on a single
Proxmox host, provisioned as code end to end: Terraform provisions VMs,
Ansible bootstraps them and installs k3s, Helm/ArgoCD deploy everything
that runs inside the cluster. See `docs/PRD.md` (why) and `docs/SPEC.md`
(architecture, living doc).

## Repository Structure

```
docs/         # PRD.md, SPEC.md (living doc), TICKETS.md
terraform/    # VM provisioning (Phase 1)
ansible/      # VM bootstrap + k3s install (Phase 2)
k8s/          # Helm values / manifests / ArgoCD app defs (Phase 3+)
scripts/      # one-off host scripts (e.g. cloud-init template build)
hooks/        # tracked pre-commit hook source (installed via `make install-hooks`)
.github/      # CI workflows
.claude/      # Claude Code adapter scripts (dev-check.sh)
```

## Environment

- No language runtime to manage (no uv/venv) — this repo's "code" is
  Terraform, Ansible YAML, Helm values, and a handful of bash scripts.
- Lint locally: `make lint` (shellcheck on every tracked `.sh` file, plus
  `terraform fmt -check`/`terraform validate` and `ansible-lint` once
  those directories exist).
- Secrets: none committed, ever. Terraform/Ansible secrets (Proxmox API
  token, SSH keys, DB passwords) stay out of git — see `docs/SPEC.md` §6
  for the Sealed Secrets plan once the cluster exists; for Terraform/Ansible
  themselves, use `.tfvars`/vault-encrypted files, both gitignored.

---

## PM / Developer / QA Workflow

Three-role workflow, same as every other project in this portfolio.

- **PM** — owns `docs/TICKETS.md`, confirms an ask maps to an existing
  ticket (or writes one before starting), confirms whether it needs a
  `docs/SPEC.md` update in the same commit. Never writes code.
- **Developer** — implements one ticket at a time, smallest coherent
  change, one type of change per PR (don't mix a Terraform change with an
  Ansible change with a doc fix). Shellchecks any bash before proposing
  it for merge. Never self-approves own work.
- **QA** — verifies independently: `terraform validate`/`terraform plan`
  shows only the expected diff, `ansible-lint` passes, the change was
  actually exercised (applied/run), not just "looks right." Updates the
  ticket's status in `docs/TICKETS.md` only after this. Never self-closes
  own work.

State the active role explicitly per turn — never blend roles in one
response.

**Cadence:** one ticket at a time, always. Never run straight through the
backlog unsupervised. The ticket is reviewed before implementation starts
— this is the highest-leverage checkpoint and the one place human judgment
is irreplaceable, especially here since a "ticket" can mean a real change
to a running home-lab host.

**Per-ticket checklist:**
- [ ] Ticket reviewed before implementation starts
- [ ] Actual files read, not just a summary of them
- [ ] `terraform plan` / `ansible-lint` / shellcheck run and actually
      inspected, not just reported as passed
- [ ] `git status` / `git diff` checked before trusting any state claim
- [ ] No secret-bearing file in the staged commit
- [ ] Committed immediately after approval, before the next ticket starts
- [ ] `docs/TICKETS.md` status updated after QA signs off

**Never delegate:** any permanently destructive command (VM/snapshot/
backup deletion, `terraform destroy`, force-pushing history) is never
executed directly — write out the exact command(s) and let Igal run them.
The same reasoning that might have introduced a problem is poorly
positioned to catch it.

---

## Hard rules

- No direct commits to `master`. Every change is a branch + PR.
- CI must be green before merge.
- Every bash script gets shellchecked before it's merged.
- No bundling unrelated changes into one PR — if you notice something
  else that needs fixing, file it as a separate ticket/PR.
- Never run permanently destructive commands directly — describe them,
  let Igal run them.
- Always confirm current Proxmox/cluster state before proposing anything
  destructive or state-changing; don't assume prior state.
- `docs/SPEC.md` is a living doc — architecture changes land their doc
  update in the same commit.

## Don't conflate

This repo is Terraform/Ansible/k3s infrastructure only. It is not
`vault-secrets-demo`, `il-job-scraper`, or any LinkedIn/portfolio
publication workflow — those are separate threads with their own repos
and conventions.

## Explaining work

Igal has asked to understand every step, tool, and functionality used
here in full — not just receive finished files. Default to explaining
the *why* behind a change, not just the *what*, especially for anything
touching Terraform/Ansible (the two skills this project exists to prove
out).

---

## Session Handoff

At the end of every session, write `HANDOFF.md` in the repo root
(gitignored) with exactly four fields: **Current ticket**, **Last
action**, **Next step**, **Blockers**. At the start of every session,
read it before doing anything else. Prepend-and-preserve: new state goes
above the `---` separator, historical content below is never deleted
without explicit confirmation.

---

## Commit Convention

```
type(TICKET-ID): short description
type: short description   ← no ticket for pure housekeeping commits
```

Types: `feat`, `fix`, `docs`, `chore`, `ci`

Examples:
```
feat(PX-002): add Terraform VM resource definitions
fix(PX-005): correct k3s agent join token variable
ci: add shellcheck workflow
docs: update SPEC.md network table with confirmed static IPs
```

## Branch Naming

```
feature/TICKET-ID-short-description
fix/TICKET-ID-short-description
chore/short-description
```

Examples:
```
feature/PX-002-terraform-vm-resources
fix/PX-005-k3s-join-token
chore/update-gitignore
```

Default branch: `master`

---

## Always Verify Before Accepting

Never mark a ticket DONE based on a self-report. QA runs the actual
validation independently and confirms output before closing. Write the
verified result, not the assumption.

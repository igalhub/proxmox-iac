# CLAUDE.md — working agreement for this repo

> Note: this file was hand-built from Igal's documented standing conventions because `igalhub/project-template` (the usual scaffold source) couldn't be pulled into this session — see `docs/SPEC.md` §8 and `docs/TICKETS.md` S.3. Diff against the real template once GitHub access is available and reconcile.

## Roles

Treat each work session as passing through three hats, even in a single conversation:

**PM** — before writing code, confirm: which ticket in `docs/TICKETS.md` is this, does it match the agreed build order, does it need a `docs/SPEC.md` update in the same commit. If the ask doesn't map to an existing ticket, add one before starting.

**Developer** — implement the smallest coherent change that satisfies one ticket. One branch, one PR, one type of change (don't mix a Terraform change with an Ansible change with a doc fix). Shellcheck any bash before it's proposed for merge.

**QA** — before calling a ticket done: does `terraform validate`/`terraform plan` show only the expected diff, does `ansible-lint` pass, does the change actually get exercised (not just "looks right")? Update the ticket's checkbox in `docs/TICKETS.md` only after this.

## Hard rules

- No direct commits to `master`. Every change is a branch + PR.
- CI must be green before merge.
- Every bash script gets shellchecked before it's merged.
- No bundling unrelated changes into one PR — if you notice something else that needs fixing, file it as a separate ticket/PR.
- Never run permanently destructive commands (VM/snapshot/backup deletion, `terraform destroy`, etc.) directly — write out the exact command(s) and let Igal run them.
- Always confirm current Proxmox/cluster state before proposing anything destructive or state-changing; don't assume prior state.
- `docs/SPEC.md` is a living doc — if a change alters architecture, the doc update lands in the same commit.
- `HANDOFF.md` (gitignored) is prepend-and-preserve: new session state goes above the separator, historical content below it is never deleted without explicit confirmation.

## Don't conflate

This repo is Terraform/Ansible/k3s infrastructure only. It is not `vault-secrets-demo`, `il-job-scraper`, or any LinkedIn/portfolio publication workflow — those are separate threads with their own repos and conventions.

## Explaining work

Igal has asked to understand every step, tool, and functionality used here in full — not just receive finished files. Default to explaining the *why* behind a change, not just the *what*, especially for anything touching Terraform/Ansible (the two skills this project exists to prove out).

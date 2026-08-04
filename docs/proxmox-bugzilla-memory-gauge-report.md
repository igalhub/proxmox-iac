# Bug report — filed at bugzilla.proxmox.com

**Filed:** 2026-08-04 as
[Bug 7882](https://bugzilla.proxmox.com/show_bug.cgi?id=7882) — `pve`
product, `Qemu` component, Proxmox VE 9.2.3, status `NEW`.

Component: Qemu (QEMU/KVM Emulator) — the actual PVE Bugzilla component
list has no separate "pvestatd" or backend-status category; Qemu is the
closest match since this is about VM status/memory reporting, not the
Web UI or generic Backend catch-all.

## Summary

VM memory usage gauge (web UI and `pvesh get /nodes/<node>/qemu/<vmid>/status/current`)
reads raw free memory instead of cache-aware available memory, causing the
gauge to trend toward 100% on any healthy, long-running Linux guest —
despite the guest kernel already reporting the correct, cache-aware
value via the same QMP channel Proxmox already queries.

## Environment

- Proxmox VE version: 9.2.3
- QEMU version: pve-qemu-kvm 11.0.0-4
- Guest OS: Ubuntu 24.04, kernel 6.8.0-136-generic
- qemu-guest-agent: installed and running
- Ballooning: enabled (`balloon: N` set, non-zero, in VM config)

## Description

For any Linux guest with `agent: 1` and a non-zero `balloon` device
configured, Proxmox's reported memory-usage percentage (web UI gauge and
the `mem`/`maxmem` fields under
`/nodes/<node>/qemu/<vmid>/status/current`) is calculated from
`ballooninfo.free_mem`. This value is sourced from the guest's raw free-
page count (QMP's `stat-free-memory` stat on the VM's `balloon0` device),
which does **not** account for reclaimable memory such as the Linux page
cache (buffers/cached, as shown in `free -h`'s "available" column).

Because a healthy, long-running Linux system deliberately keeps `MemFree`
low (using spare RAM for disk cache, per standard kernel behavior),
Proxmox's gauge trends toward ~100% used on any such guest, regardless of
actual memory pressure — this is a permanent, structural
misrepresentation, not a transient display glitch.

## Real numbers observed

On a 3-node k3s cluster (4-8GB RAM per VM), comparing Proxmox's reported
usage against the guest's own `/proc/meminfo`-derived `MemAvailable`
(collected via node-exporter/Prometheus, cross-checked against `free -h`
inside each guest):

| VM   | Real usage (MemAvailable-based) | Proxmox UI/API shows |
|------|----------------------------------|------------------------|
| cp-1 | ~40.0% used                      | ~70.9% used             |
| wk-1 | ~29.7-30.1% used                 | ~73.8-77.7% used         |
| wk-2 | ~26.7% used                      | ~62.4-64.5% used         |

A 30-47 percentage-point gap on every node, with zero actual memory
pressure (confirmed via `kubectl top nodes`, `free -h`, and no
OOM/eviction events).

## Root cause, confirmed directly via QMP

Queried each VM's `balloon0` device directly via `qom-get` (read-only, no
state changed) to inspect the full `guest-stats` object QEMU exposes.
The guest kernel is **already reporting** the correct, cache-aware value
— `stat-available-memory` — through virtio-balloon's stats channel
(`VIRTIO_BALLOON_S_AVAIL`, supported by this kernel/QEMU combination).
It matches the guest's own `MemAvailable` almost exactly:

- cp-1: `stat-available-memory` = `2466406400` bytes (QMP) vs.
  `node_memory_MemAvailable_bytes` = `2465214464` (Prometheus), same
  instant.

Compared directly against `stat-free-memory` (the value Proxmox actually
uses):

| VM   | `stat-available-memory` (correct) | `stat-free-memory` (what Proxmox uses) |
|------|--------------------------------------|-------------------------------------------|
| cp-1 | 40.0% used                          | 74.3% used                                |
| wk-1 | 29.7% used                          | 80.8% used                                |
| wk-2 | 26.7% used                          | 64.5% used                                |

**The correct data is available at the QMP/hypervisor level right now,
without any guest-side change.** The gap is entirely in Proxmox's own
`pvestatd`/status-reporting code, which reads `stat-free-memory` into
`ballooninfo.free_mem` and never queries `stat-available-memory`, even
though it's present in the same `guest-stats` response.

## Steps to reproduce

1. Create a Linux VM with `agent: 1` and a non-zero `balloon` value set.
2. Let it run normally for a while (long enough for page cache to grow
   — a few hours of light, healthy activity is enough).
3. Compare the VM's reported memory % in the Proxmox UI (or
   `pvesh get /nodes/<node>/qemu/<vmid>/status/current --output-format json`)
   against `free -h`'s "available" column run inside the guest.
4. Optionally confirm directly: from the host,
   `echo '{"execute":"qom-get","arguments":{"path":"/machine/peripheral/balloon0","property":"guest-stats"}}' | \
   sudo qm monitor <vmid>` (or via `qm agent`/`socat` to the VM's QMP
   socket) and compare `stat-available-memory` against `stat-free-memory`
   in the response.

## Expected behavior

The memory-usage gauge/API should reflect reclaimable-aware available
memory (matching what `free -h`'s "available" column and the guest's own
`MemAvailable` report), not raw free pages — using
`stat-available-memory` from the same QMP `guest-stats` response already
being read for `stat-free-memory`, when the guest/QEMU version supports
it (falling back to the current `stat-free-memory`-based calculation
otherwise, for older guests/QEMU that don't report the extended stat).

## Actual behavior

Gauge/API reports raw free-page usage, trending toward 100% on any
healthy long-running Linux guest with reclaimable page cache, regardless
of real memory pressure.

## Additional notes

Happy to provide the full raw QMP `guest-stats` JSON response, exact
`pveversion -v` output, or any other diagnostic on request.

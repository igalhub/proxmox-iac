#!/usr/bin/env bash
# proxmox-iac :: step 1 — build Ubuntu 24.04 cloud-init template
#
# Run this ON THE PROXMOX HOST (root@192.168.10.50), not from a dev
# machine — this creates a real VM template on physical hardware, so per
# CLAUDE.md this is described here, not executed by an agent.
#
# Before running: confirm the two variables below against your host.
#   pvesm status          -> confirms STORAGE pool name (e.g. local-lvm, local-zfs)
#   ip a / brctl show     -> confirms BRIDGE name (usually vmbr0)
#   qm list                -> confirms VMID is not already in use
#   free -h                -> confirms actual free RAM before Phase 1 sizing (docs/SPEC.md §3 open item)

set -euo pipefail

VMID=9000                                  # template VM ID — pick something outside your normal VM range
VMNAME="ubuntu-2404-cloudinit-template"
STORAGE="local-lvm"                        # CHANGE if your storage pool has a different name
BRIDGE="vmbr0"                             # CHANGE if your bridge has a different name
DISK_SIZE_GB=8                             # bumped from cloud image's default ~2.2G so clones have headroom
MEMORY_MB=2048
CORES=2

IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_FILE="/var/tmp/noble-server-cloudimg-amd64.img"

echo "=== 1. Download Ubuntu 24.04 (Noble) cloud image ==="
wget -q --show-progress -O "${IMAGE_FILE}" "${IMAGE_URL}"

echo "=== 2. Create the base VM shell ==="
qm create "${VMID}" \
  --name "${VMNAME}" \
  --memory "${MEMORY_MB}" \
  --cores "${CORES}" \
  --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26

echo "=== 3. Import the cloud image as a disk ==="
qm importdisk "${VMID}" "${IMAGE_FILE}" "${STORAGE}"

echo "=== 4. Attach the imported disk as scsi0 ==="
qm set "${VMID}" \
  --scsihw virtio-scsi-pci \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

echo "=== 5. Add the cloud-init drive (ide2) ==="
qm set "${VMID}" --ide2 "${STORAGE}:cloudinit"

echo "=== 6. Boot from scsi0, serial console (cloud images have no video device) ==="
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --serial0 socket --vga serial0

echo "=== 7. Enable the QEMU guest agent ==="
qm set "${VMID}" --agent enabled=1

echo "=== 8. Grow the disk so cloned VMs have room to work with ==="
qm resize "${VMID}" scsi0 "+${DISK_SIZE_GB}G"

echo "=== 9. Convert to template ==="
# NOTE: deliberately NOT setting --ciuser/--cipassword/--sshkey here.
# Per-VM identity (user, SSH key, IP) belongs in Terraform's cicustom/ipconfig
# block at clone time, not baked into the shared template.
qm template "${VMID}"

echo "=== Done. Template VMID ${VMID} (${VMNAME}) is ready for Terraform to clone. ==="
qm config "${VMID}"

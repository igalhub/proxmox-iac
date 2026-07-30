# cp-1/wk-1/wk-2 differ only in sizing/IP/VMID (docs/SPEC.md §3), so they're
# generated from one resource via for_each rather than copy-pasted three times.
locals {
  nodes = {
    "cp-1" = { vm_id = 110, ip_octet = 10, cores = 2, memory = 4096, disk_size = 40 }
    "wk-1" = { vm_id = 111, ip_octet = 11, cores = 3, memory = 8192, disk_size = 60 }
    "wk-2" = { vm_id = 112, ip_octet = 12, cores = 3, memory = 8192, disk_size = 60 }
  }
}

resource "proxmox_virtual_environment_vm" "k3s_node" {
  for_each = local.nodes

  name      = each.key
  node_name = var.proxmox_node_name
  vm_id     = each.value.vm_id

  clone {
    vm_id        = var.template_vm_id
    datastore_id = "local-lvm"
    full         = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_size
  }

  network_device {
    bridge = "vmbr0"
  }

  # Matches the PX-003 template's headless serial-console setup (vga:
  # serial0 / serial0: socket in `qm config 9000`) — pinned explicitly so
  # Terraform doesn't drift it back to the provider's own "std" default.
  vga {
    type = "serial0"
  }

  serial_device {
    device = "socket"
  }

  agent {
    enabled = true
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "${var.network_prefix}.${each.value.ip_octet}/24"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = var.vm_ssh_username
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }
  }
}

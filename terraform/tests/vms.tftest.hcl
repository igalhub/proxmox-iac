# Native Terraform test suite (PX-033) — mocked provider only, never
# touches the real Proxmox host or its API token. Asserts on this
# repo's own config logic (sizing, IP/VMID correlation, PX-023's
# ballooning-floor values), not on provider behavior — the provider
# itself is still verified for real via `terraform plan`/`apply`
# against the live host, same as every prior VM-affecting ticket
# (see docs/SPEC.md §10).

mock_provider "proxmox" {}

variables {
  proxmox_endpoint  = "https://mock.invalid:8006/"
  proxmox_api_token = "mock@pve!mock=00000000-0000-0000-0000-000000000000"
  # vms.tf's `file(pathexpand(var.ssh_public_key_path))` is a Terraform
  # Core builtin, evaluated before the mocked provider ever sees the
  # config — mock_provider does NOT shield this. The real default
  # (~/.ssh/homelab.pub) only exists on the machine that actually owns
  # this project's SSH key, so it must be overridden here to a checked-in
  # fixture or every environment without that exact key (CI included)
  # fails at plan time, not because the resource logic is wrong.
  ssh_public_key_path = "./tests/fixtures/mock-ssh-key.pub"
}

run "cp1_sizing_and_network" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["cp-1"].vm_id == 110
    error_message = "cp-1 should be VMID 110"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["cp-1"].cpu[0].cores == 2
    error_message = "cp-1 should have 2 cores"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["cp-1"].memory[0].dedicated == 4096
    error_message = "cp-1 should have 4096MB dedicated memory"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["cp-1"].disk[0].size == 40
    error_message = "cp-1 should have a 40GB disk"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["cp-1"].initialization[0].ip_config[0].ipv4[0].address == "192.168.10.10/24"
    error_message = "cp-1 should be assigned 192.168.10.10/24"
  }
}

run "wk1_sizing_and_network" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-1"].vm_id == 111
    error_message = "wk-1 should be VMID 111"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-1"].cpu[0].cores == 3
    error_message = "wk-1 should have 3 cores"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-1"].memory[0].dedicated == 8192
    error_message = "wk-1 should have 8192MB dedicated memory"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-1"].disk[0].size == 60
    error_message = "wk-1 should have a 60GB disk"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-1"].initialization[0].ip_config[0].ipv4[0].address == "192.168.10.11/24"
    error_message = "wk-1 should be assigned 192.168.10.11/24"
  }
}

run "wk2_sizing_and_network" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-2"].vm_id == 112
    error_message = "wk-2 should be VMID 112"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-2"].cpu[0].cores == 3
    error_message = "wk-2 should have 3 cores"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-2"].memory[0].dedicated == 8192
    error_message = "wk-2 should have 8192MB dedicated memory"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-2"].disk[0].size == 60
    error_message = "wk-2 should have a 60GB disk"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-2"].initialization[0].ip_config[0].ipv4[0].address == "192.168.10.12/24"
    error_message = "wk-2 should be assigned 192.168.10.12/24"
  }
}

run "vmid_matches_ip_octet_for_every_node" {
  command = plan

  # Structural invariant (docs/SPEC.md §4): each VMID's last two digits
  # equal its static IP's last octet (110<->.10, 111<->.11, 112<->.12) —
  # asserted generically over all nodes, not just hardcoded per-VM, so
  # this keeps holding if a 4th node is ever added.
  assert {
    condition = alltrue([
      for name, node in local.nodes :
      proxmox_virtual_environment_vm.k3s_node[name].vm_id == 100 + node.ip_octet
    ])
    error_message = "every node's VMID should be 100 + its static IP's last octet"
  }
}

run "ballooning_floor_values_and_relationship" {
  command = plan

  # PX-023: cp-1 gets a tighter floor (87.5%, 512MB reclaimable) than
  # wk-1/wk-2 (75%, 2048MB reclaimable) — it's the sole control-plane
  # with no HA and runs etcd, so it gets less room to give under
  # reclaim pressure. Asserted both as exact values (catch an
  # accidental change to the wrong number) and as a relationship
  # (catch a change that keeps the numbers "reasonable" but breaks the
  # actual cp-1-tighter-than-workers intent).
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["cp-1"].memory[0].floating == 3584
    error_message = "cp-1's ballooning floor should be 3584MB (87.5% of 4096MB)"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-1"].memory[0].floating == 6144
    error_message = "wk-1's ballooning floor should be 6144MB (75% of 8192MB)"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.k3s_node["wk-2"].memory[0].floating == 6144
    error_message = "wk-2's ballooning floor should be 6144MB (75% of 8192MB)"
  }
  assert {
    condition = (
      proxmox_virtual_environment_vm.k3s_node["cp-1"].memory[0].floating
      / proxmox_virtual_environment_vm.k3s_node["cp-1"].memory[0].dedicated
      ) > (
      proxmox_virtual_environment_vm.k3s_node["wk-1"].memory[0].floating
      / proxmox_virtual_environment_vm.k3s_node["wk-1"].memory[0].dedicated
    )
    error_message = "cp-1's floor should be a tighter fraction of its dedicated memory than wk-1's"
  }
}

run "outputs_derive_correctly" {
  command = plan

  assert {
    condition     = output.vm_ips["cp-1"] == "192.168.10.10"
    error_message = "vm_ips output should map cp-1 to 192.168.10.10"
  }
  assert {
    condition     = output.vm_ids["wk-2"] == 112
    error_message = "vm_ids output should map wk-2 to VMID 112"
  }
}

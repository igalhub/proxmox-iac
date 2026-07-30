output "vm_ips" {
  description = "Static IP assigned to each cloned VM"
  value       = { for name, node in local.nodes : name => "${var.network_prefix}.${node.ip_octet}" }
}

output "vm_ids" {
  description = "Proxmox VMID assigned to each cloned VM"
  value       = { for name, vm in proxmox_virtual_environment_vm.k3s_node : name => vm.vm_id }
}

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://192.168.10.50:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification (true for the host's self-signed cert)"
  type        = bool
  default     = true
}

variable "proxmox_node_name" {
  description = "Proxmox node name (not the IP/hostname) — confirmed live via `pvesh get /nodes`"
  type        = string
  default     = "pve"
}

variable "template_vm_id" {
  description = "VMID of the PX-003 cloud-init template to clone from"
  type        = number
  default     = 9000
}

variable "network_prefix" {
  description = "First three octets of the lab's static IP range"
  type        = string
  default     = "192.168.10"
}

variable "network_gateway" {
  description = "Default gateway for the cloned VMs"
  type        = string
  default     = "192.168.10.1"
}

variable "vm_ssh_username" {
  description = "Initial cloud-init user account (Ansible creates the hardened deploy user afterward)"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Path to the public key injected via cloud-init for the initial user"
  type        = string
  default     = "~/.ssh/homelab.pub"
}

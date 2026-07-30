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

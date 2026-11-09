variable "cluster_name" {
  type    = string
  default = "marvelx"
}

variable "node_image" {
  type    = string
  default = "kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
}

variable "worker_count" {
  type    = number
  default = 1
}

variable "state_passphrase" {
  type      = string
  sensitive = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "The state passphrase must be at least 16 characters."
  }
}

variable "terraform_state_bucket" {
  description = "The GCS bucket containing the bootstrap Terraform state."
  type        = string

  validation {
    condition     = length(trimspace(var.terraform_state_bucket)) > 0
    error_message = "terraform_state_bucket must not be empty."
  }
}

variable "enable_https" {
  description = "Whether to create the Google-managed TLS certificate."
  type        = bool
  default     = false
}

variable "manage_dns" {
  description = "Whether Terraform should manage the public DNS A record."
  type        = bool
  default     = false
}

variable "create_dns_zone" {
  description = "Whether Terraform should create the public DNS zone instead of using an existing zone."
  type        = bool
  default     = false

  validation {
    condition     = !var.create_dns_zone || var.manage_dns
    error_message = "create_dns_zone may be true only when manage_dns is true."
  }
}

variable "dns_name" {
  description = "The application hostname, without a trailing dot, used for DNS and HTTPS."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = !(var.enable_https || var.manage_dns) || try(
      var.dns_name != null &&
      length(trimspace(var.dns_name)) > 0 &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", lower(trimspace(var.dns_name)))),
      false,
    )
    error_message = "dns_name must be a valid non-empty hostname without a trailing dot when HTTPS or DNS management is enabled."
  }
}

variable "dns_zone_name" {
  description = "The Cloud DNS managed-zone resource name used when DNS management is enabled."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = !var.manage_dns || try(
      var.dns_zone_name != null &&
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", trimspace(var.dns_zone_name))),
      false,
    )
    error_message = "dns_zone_name must be a valid non-empty Cloud DNS managed-zone name when DNS management is enabled."
  }
}

variable "dns_zone_dns_name" {
  description = "The trailing-dot DNS suffix for a public zone created by Terraform."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = !var.create_dns_zone || try(
      var.dns_zone_dns_name != null &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+$", lower(trimspace(var.dns_zone_dns_name)))) &&
      (
        "${trimsuffix(lower(trimspace(var.dns_name)), ".")}." == lower(trimspace(var.dns_zone_dns_name)) ||
        endswith("${trimsuffix(lower(trimspace(var.dns_name)), ".")}.", ".${lower(trimspace(var.dns_zone_dns_name))}")
      ),
      false,
    )
    error_message = "dns_zone_dns_name must be a valid trailing-dot suffix containing dns_name when Terraform creates the DNS zone."
  }
}

variable "dev_principals" {
  description = "Optional IAM principals receiving the reviewed developer roles."
  type        = list(string)
  default     = []
  nullable    = true

  validation {
    condition     = var.dev_principals == null ? true : alltrue([for principal in var.dev_principals : length(trimspace(principal)) > 0])
    error_message = "dev_principals must be null or contain only non-empty IAM principal strings."
  }
}

variable "ops_principals" {
  description = "Optional IAM principals receiving the reviewed operations roles."
  type        = list(string)
  default     = []
  nullable    = true

  validation {
    condition     = var.ops_principals == null ? true : alltrue([for principal in var.ops_principals : length(trimspace(principal)) > 0])
    error_message = "ops_principals must be null or contain only non-empty IAM principal strings."
  }
}

variable "sre_principals" {
  description = "Optional IAM principals receiving the reviewed SRE roles."
  type        = list(string)
  default     = []
  nullable    = true

  validation {
    condition     = var.sre_principals == null ? true : alltrue([for principal in var.sre_principals : length(trimspace(principal)) > 0])
    error_message = "sre_principals must be null or contain only non-empty IAM principal strings."
  }
}

variable "cluster_admin_email" {
  description = "Google user email receiving permanent Connect Gateway and Kubernetes cluster-admin access."
  type        = string

  validation {
    condition = can(regex(
      "^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$",
      lower(trimspace(var.cluster_admin_email)),
    ))
    error_message = "cluster_admin_email must be a valid bare Google user email."
  }
}

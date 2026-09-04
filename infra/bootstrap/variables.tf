variable "project_id" {
  description = "The GCP project ID to create or attach to."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must not be empty."
  }
}

variable "create_project" {
  description = "Whether to create the GCP project instead of attaching to an existing project."
  type        = bool
}

variable "project_name" {
  description = "The display name to use when creating the GCP project."
  type        = string

  validation {
    condition     = !var.create_project || length(trimspace(var.project_name)) > 0
    error_message = "project_name must not be empty when create_project is true."
  }
}

variable "billing_account" {
  description = "The billing account to attach when creating the GCP project."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.create_project || (var.billing_account != null && length(trimspace(var.billing_account)) > 0)
    error_message = "billing_account must be set when create_project is true."
  }
}

variable "folder_id" {
  description = "The optional folder parent to use when creating the GCP project."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.create_project || var.folder_id == null || var.organization_id == null
    error_message = "At most one of folder_id and organization_id may be set when create_project is true."
  }
}

variable "organization_id" {
  description = "The optional organization parent to use when creating the GCP project."
  type        = string
  default     = null
  nullable    = true
}

variable "state_bucket_name" {
  description = "The globally unique name of the Terraform state bucket."
  type        = string

  validation {
    condition     = length(trimspace(var.state_bucket_name)) > 0
    error_message = "state_bucket_name must not be empty."
  }
}

variable "state_bucket_location" {
  description = "The location in which to create the Terraform state bucket."
  type        = string

  validation {
    condition     = length(trimspace(var.state_bucket_location)) > 0
    error_message = "state_bucket_location must not be empty."
  }
}

variable "github_repository" {
  description = "The GitHub repository in OWNER/REPO form allowed to deploy."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must have the form OWNER/REPO."
  }
}

variable "github_repository_id" {
  description = "The immutable numeric GitHub repository ID allowed to deploy."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must contain only digits."
  }
}

variable "github_owner_id" {
  description = "The immutable numeric GitHub repository owner ID allowed to deploy."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must contain only digits."
  }
}

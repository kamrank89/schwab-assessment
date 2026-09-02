variable "terraform_state_bucket" {
  description = "The GCS bucket containing the foundation Terraform state."
  type        = string

  validation {
    condition     = length(trimspace(var.terraform_state_bucket)) > 0
    error_message = "terraform_state_bucket must not be empty."
  }
}

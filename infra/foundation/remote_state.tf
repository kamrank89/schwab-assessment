data "terraform_remote_state" "bootstrap" {
  backend = "gcs"

  config = {
    bucket = var.terraform_state_bucket
    prefix = "bootstrap"
  }
}

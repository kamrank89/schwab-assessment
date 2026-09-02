resource "google_compute_security_policy" "assessment" {
  project = local.project_id
  name    = "schwab-assessment"

  description = "Edge protections for the GKE assessment applications"

  rule {
    action   = "throttle"
    priority = 1000

    description = "Per-IP request throttle"

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
    }
  }

  rule {
    action   = "deny(403)"
    priority = 2000
    preview  = true

    description = "SQL injection protection in preview"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 2})"
      }
    }
  }

  rule {
    action   = "deny(403)"
    priority = 2100
    preview  = true

    description = "Cross-site scripting protection in preview"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 2})"
      }
    }
  }

  rule {
    action   = "allow"
    priority = 2147483647

    description = "Default allow"

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  depends_on = [google_project_service.required["compute.googleapis.com"]]
}

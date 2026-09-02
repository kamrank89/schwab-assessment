# Security and production limitations

This repository demonstrates a coherent assessment architecture; it is not a production accreditation, penetration test, availability result, or compliance control set.

- **No live proof:** no cloud authentication, plan/apply, endpoint, IAM evaluation, secret mount, dashboard, query result, failover, HPA response, teardown, or residual check has been run for this delivery.
- **One broad deployer:** `assessment-deployer` spans creation, verification, and destruction. Production needs identity/role separation and independent approval.
- **Baseline WIF subject:** only the `main` branch subject is allowed. Protected GitHub Environments are recommended but require a WIF-first subject migration and are not configured by repository automation.
- **HTTP-first endpoint:** the immediately deployable path is unencrypted HTTP by IP. Production needs an owned domain, active TLS, appropriate redirect/HSTS policy, and security review.
- **Private nodes, reachable Google API endpoint:** node IPs are private and cluster IP endpoints are disabled, but the GKE DNS control-plane endpoint allows external traffic through Google APIs and relies on IAM/RBAC. Consider VPC Service Controls, Private Service Connect/Private Google Access, and runner placement for production.
- **Cloud Armor posture:** rate limiting is enforced; SQLi/XSS rules are preview-only. Tune and observe rules before enforcement, add organization-specific allow/deny/bot/DDoS controls, and test false positives.
- **NetworkPolicy is not a whole-platform firewall:** manifests restrict basic workload paths, while actual enforcement and all required DNS/Google API/plugin egress must be live-tested.
- **Public third-party images:** the repository owns no application source or build. Digest pins do not provide attestations, SBOMs, or vulnerability remediation guarantees.
- **Telemetry limits:** basic logs/metrics are configured, but Trace requires supported automatic capture or application/OpenTelemetry instrumentation; Profiler requires a language agent; Error Reporting requires recognizable exception logs or API calls. These public demo images cannot substantiate “full” application traces/profiles/errors.
- **Grafana is recoverable, not highly available:** one primary-cluster replica uses `emptyDir`; committed provisioning is authoritative and UI changes are not durable.
- **MCI/MCS migration debt:** the rubric-first ingress must be migrated to multi-cluster Gateway API after feature-parity and cutover testing.
- **No data platform:** both applications are stateless demonstrations. There is no database, backup/restore, cross-region data consistency, or application RPO/RTO evidence.
- **No cluster backup:** teardown is intended to delete the assessment. GKE Backup, persistent-volume protection, and disaster restore are absent.
- **Costs are usage-dependent:** free-tier credits are account-scoped and incomplete. Two clusters, MCI backend Pods, load balancing, NAT, Armor, logs, BigQuery, Monitoring, secrets, storage, DNS, and traffic can all bill.
- **Shell trap boundary:** scripts restore on ordinary exit, HUP, INT, and TERM, but no process can run a cleanup trap after `SIGKILL`, runner loss, or some infrastructure failures. Rerun guarded recovery.
- **Governance checklist only:** branch rules, CODEOWNERS, Environment reviewers, prevent-self-review, and deployment restrictions are recommendations, not API-created prerequisites or verified settings.

Production acceptance requires threat modeling, organization-policy review, least-privilege IAM testing, load/capacity testing, failure injection, data classification, privacy/log redaction, incident procedures, cost budgets/alerts, SLOs, and independently reviewed live evidence.

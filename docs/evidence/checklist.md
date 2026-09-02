# Post-deployment evidence checklist

Use this only after an authorized manual workflow. Collect the minimum result needed, redact before storage, and never capture tokens, credentials, Secret Manager values, Terraform state/plans, kubeconfigs, full HTTP bodies, or unreviewed log/query rows. Every promoted record must satisfy [live-evidence-template.md](live-evidence-template.md).

## Deployment identity

- [ ] UTC start/end time and deployed commit SHA
- [ ] `deploy.yml` workflow URL and job URLs
- [ ] actor and independent reviewer/approver
- [ ] project ID and regions, with no billing/account/person identifiers beyond what is approved
- [ ] explicit redaction note and secure artifact location

## Cluster and Fleet readiness

- [ ] `gke-assessment-us-central1` cluster `RUNNING`
- [ ] `gke-assessment-us-east1` cluster `RUNNING`
- [ ] both matching Fleet memberships `READY`
- [ ] access method identified as DNS endpoint bootstrap plus Connect Gateway, without kubeconfig content

## Application baseline

- [ ] App A in `us-central1`: desired/Ready/updated/available = 3
- [ ] App A in `us-east1`: desired/Ready/updated/available = 3
- [ ] App B in `us-central1`: desired/Ready/updated/available = 3
- [ ] App B in `us-east1`: desired/Ready/updated/available = 3
- [ ] state explicitly summarized as six Ready replicas per application across both regions
- [ ] rollout success for all four Deployments

## Global routing and security

- [ ] MCI VIP assigned and equal to Terraform's reserved address
- [ ] exactly `app-a-mcs` and `app-b-mcs` present
- [ ] both backend services report nonempty, entirely `HEALTHY` status
- [ ] both BackendConfigs reference the expected Cloud Armor policy
- [ ] HTTP `/app-a` and `/app-b` status codes recorded without bodies
- [ ] if HTTPS enabled: owned DNS, HTTP 3xx, certificate `ACTIVE`, and HTTPS 2xx for both paths
- [ ] if HTTPS disabled: mark the HTTPS row `not-applicable`; do not claim TLS
- [ ] if returning from HTTPS to HTTP: first-dispatch URL proves HTTP MCI reconciliation and both routes 2xx, both TLS/frontend annotations absent, and zero target HTTPS/SSL proxy references; second ordinary-dispatch URL proves certificate/DNS convergence and HTTP 2xx

## Workload identity and secrets

- [ ] App A and Grafana CSI mounts verified by metadata/file-presence check without reading values into output
- [ ] App B has no GSA annotation and no mounted service-account token
- [ ] least-access behavior checked only with a reviewed non-secret method

## BigQuery and Grafana

- [ ] exact routed BigQuery tables `stdout`, `requests`, `kubelet`, and `kube_apiserver` passed the bounded top-level schema-compatibility gate
- [ ] all seven committed SQL files complete a live dry run
- [ ] any actual query uses a bounded UTC/partition window; output is minimized and redacted; schema-discovery payloads and log rows are not uploaded
- [ ] Grafana Deployment has one Ready/available primary-cluster replica
- [ ] the exact dashboard ConfigMap referenced by the current Grafana Deployment contains exactly the three expected JSON exports; stale hash-suffixed maps are excluded
- [ ] dashboard artifact is the committed JSON export; a redacted live screenshot is optional and requires a separately approved temporary human IAM/RBAC access record outside the baseline
- [ ] screenshot/export shows the four overview panels: error rate, restarts, p50/p95/p99 latency, CPU/memory

## Optional exercises — only if deliberately selected

- [ ] HPA drill record shows exact confirmation, baseline, temporary four-replica reconciliation for both apps, and committed-overlay reapplication/rollout completion
- [ ] a subsequent smoke record independently proves exact three-replica restoration before that claim is promoted
- [ ] HPA is described as controller reconciliation, not CPU load evidence
- [ ] failover drill record shows exact confirmation, selected region, five consecutive successful route checks, and committed-overlay reapplication/rollout completion
- [ ] a subsequent smoke record independently proves exact three-replica restoration before that claim is promoted
- [ ] failover is described as application-backend removal, not cluster/regional infrastructure outage
- [ ] if an exercise was not selected, mark it `not-applicable` for that run

## Troubleshooting exercise

- [ ] if executed, record the actual symptom, hypotheses, read-only diagnostics, identified cause, reviewed correction, recovery proof, and prevention
- [ ] do not promote the planned readiness-probe scenario until it was intentionally authorized and executed

## Teardown and residuals

- [ ] separate `teardown.yml` workflow URL, UTC time, commit, actor, and reviewer
- [ ] MCI controller inventory was captured before deletion and removed only after success
- [ ] normal path: workloads/MCI/MCS deleted before platform, then foundation, completion marker bound before live inventory removal; foundation-only path records either complete never-created proof or exact completion-bound empty-platform proof and the corresponding skipped cleanup/stage result
- [ ] redacted report states each cleanup/stage result without presenting skipped or already-empty stages as deleted
- [ ] residual check records the intentionally retained project, state bucket/state prefixes and versions, WIF provider, deployer identity/IAM, and bootstrap APIs
- [ ] billing report checked after provider lag; no literal $0 guarantee
- [ ] external DNS/delegation cleanup recorded when applicable
- [ ] optional redeploy has its own new deployment/smoke record

After review, update [status.md](status.md) row-by-row. One successful check must not promote unrelated rows.

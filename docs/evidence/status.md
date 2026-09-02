# Evidence status

Last account-free validation: 2026-09-02 UTC in the `assessment-implementation` worktree. No Google Cloud authentication, Terraform plan/apply/destroy, lifecycle script, `gcloud`, `bq`, `gh`, deployment, drill, or teardown command was run for this documentation task.

## Status vocabulary

- `verified-account-free`: the named local/static command completed successfully; it says nothing about a cloud deployment.
- `deployment-evidence-pending`: the claim needs an authorized live run and complete [live evidence record](live-evidence-template.md).
- `not-applicable`: an optional scope was explicitly disabled for a particular completed live record, with the reason recorded. It is not a synonym for untested.
- `verified-live`: future-only status after a reviewer approves a complete live evidence record. No current row has this status.

## Account-free results actually run

| Scope | Command | Result | Status |
| --- | --- | --- | --- |
| Full repository validation | `make validate` | Exit 0. Terraform formatting and all three `init -backend=false` validations succeeded; Kubernetes summaries had zero invalid/errors; Bash/ShellCheck, actionlint, and Grafana JSON parsing succeeded. GKE-specific schemas were skipped where unavailable. | `verified-account-free` |
| Requirements preservation | `git show HEAD:docs/requirments.md \| cmp - docs/requirements/assessment-source.md` | Exit 0; renamed source is byte-for-byte equal to the tracked supplied source. | `verified-account-free` |
| Whitespace | `git diff --check` | Exit 0; no output. | `verified-account-free` |
| Sensitive generated artifact search | `find . -type f \( -name '*.tfplan' -o -name '*.tfstate' -o -name '*.pem' -o -name '*service-account*.json' -o -name 'kubeconfig*' \) -not -path './.git/*' -print` | Exit 0; no output. | `verified-account-free` |
| Grafana export alternative | `make validate` (`validate-grafana`) plus committed JSON inventory | Three dashboard JSON exports parse, including the four named overview panels. This is an export artifact, not a live screenshot or datasource result. | `verified-account-free` |

The command output existed only in the local task session; no fabricated evidence artifact was created. The next CI run may independently reproduce the static result for the committed SHA.

## Live status

| Live claim | Current status | Required evidence destination |
| --- | --- | --- |
| Human bootstrap, WIF/IAM behavior, and remote bootstrap state | `deployment-evidence-pending` | Bootstrap/delivery record |
| Foundation/platform plan/apply and remote state locking | `deployment-evidence-pending` | Deployment workflow record |
| Both clusters `RUNNING` and Fleet memberships `READY` | `deployment-evidence-pending` | Cluster/Fleet record |
| Six Ready replicas per application across both regions | `deployment-evidence-pending` | Workload record |
| MCI VIP, MCS objects, healthy backends, and global routing | `deployment-evidence-pending` | MCI/backend record |
| HTTP 2xx for both application routes | `deployment-evidence-pending` | Endpoint record |
| Optional DNS, active certificate, HTTP redirect, and HTTPS 2xx | `deployment-evidence-pending` | DNS/TLS record; `not-applicable` only within a completed HTTP-only deployment record |
| Cloud Armor attachment and runtime policy behavior | `deployment-evidence-pending` | Security/backend record |
| Workload Identity and Secret Manager runtime mounts | `deployment-evidence-pending` | Redacted IAM/secret record |
| BigQuery routed tables, SQL dry runs, and bounded query results | `deployment-evidence-pending` | BigQuery record |
| Grafana Pod, datasources, and populated live panels | `deployment-evidence-pending` | Grafana record; committed export is static only |
| Planned readiness-probe troubleshooting exercise | `deployment-evidence-pending` | Troubleshooting record |
| Optional HPA reconciliation exercise and restoration | `deployment-evidence-pending` | HPA record; `not-applicable` only when omitted from a completed run |
| Optional application failover exercise and restoration | `deployment-evidence-pending` | Failover record; `not-applicable` only when omitted from a completed run |
| Guarded teardown, controller cleanup, and residual resources | `deployment-evidence-pending` | Teardown/residual record |
| Redeploy from retained bootstrap/state | `deployment-evidence-pending` | New deployment and smoke records |
| Actual cost and post-teardown dormant spend | `deployment-evidence-pending` | Billing/cost record |

Promote rows independently. A successful deployment does not prove a drill or teardown; a committed dashboard export does not prove runtime Grafana; an empty artifact search does not prove that a future workflow will never expose sensitive data.

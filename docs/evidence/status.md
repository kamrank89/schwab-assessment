# Evidence status

Last account-free validation: 2026-09-03 UTC in the `permanent-cluster-grafana-access` worktree. The real local access, teardown-preflight, and rendering interfaces were exercised only against controlled fake external commands or fixture values. No Google Cloud authentication, Terraform plan/apply/destroy/state operation, real Cloud SDK/`kubectl`/`bq`/`gh` call, workflow dispatch, deployment, drill, or teardown mutation was run.

## Status vocabulary

- `verified-account-free`: the named local/static command completed successfully; it says nothing about a cloud deployment.
- `deployment-evidence-pending`: the claim needs an authorized live run and complete [live evidence record](live-evidence-template.md).
- `implementation-deferred`: the repository does not implement the requirement; it cannot be promoted by deploying the current baseline. A reviewed implementation must exist before live verification is meaningful.
- `not-applicable`: the supplied assessment makes the scope optional or it does not apply to the deliberately selected architecture, and the reason is recorded. A completed live record repeats that disposition for its run. It is not a synonym for untested or unimplemented required work.
- `verified-live`: future-only status after a reviewer approves a complete live evidence record. No current row has this status.

## Account-free results actually run

| Scope | Command | Result | Status |
| --- | --- | --- | --- |
| Full repository validation | `make validate` | Exit 0. Terraform formatting and all three `init -backend=false` validations succeeded; Kubernetes summaries had zero invalid/errors; Bash/ShellCheck, actionlint, Grafana JSON parsing, and the committed access/teardown/renderer regressions succeeded. GKE-specific schemas were skipped where unavailable. | `verified-account-free` |
| Authorized teardown safety round | `bash -n scripts/teardown.sh`; `shellcheck scripts/teardown.sh`; `make validate`; tracked-Markdown relative-link scan; sensitive-artifact search; `git diff --check` | Exit 0. The completion-bound empty-platform path and exact live/noncurrent/soft-deleted object classifier passed repository-native syntax/static checks. No lifecycle path or cloud behavior was exercised. | `verified-account-free` |
| Final integration focused checks | `bash -n` and `shellcheck` for `deploy.sh`, `teardown.sh`, and `verify.sh`; `actionlint` for `deploy.yml`; focused Kustomize/Kubeconform renders | Exit 0. All four changed control flows passed syntax/static workflow analysis; the primary workload and HTTP/TLS/HTTPS config overlays rendered with zero invalid resources or errors. This does not exercise a cloud lifecycle path. | `verified-account-free` |
| Focused immutable-subject regression checks | `terraform fmt -check -recursive infra`; bootstrap `init -backend=false` and `validate`; `bash -n scripts/bootstrap.sh`; `shellcheck scripts/bootstrap.sh` | Exit 0 after standard formatting; bootstrap Terraform and recovery-script syntax/static analysis succeeded. This does not mint or inspect a GitHub token. | `verified-account-free` |
| Requirements preservation | `git show eb21425a79a0b03a763d0c90571eea1cf11c9df3:docs/requirments.md \| cmp - docs/requirements/assessment-source.md` | Exit 0; the renamed file is byte-for-byte equal to the supplied source at the pre-documentation base commit. | `verified-account-free` |
| Relative documentation targets | shell/Perl scan of tracked Markdown inline links | Exit 0; no missing local targets. | `verified-account-free` |
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
| BigQuery exact routed-table/schema readiness, SQL dry runs, and bounded query results | `deployment-evidence-pending` | BigQuery record |
| Grafana Pod and current Deployment-referenced dashboard ConfigMap | `deployment-evidence-pending` | Smoke record; committed export is static only |
| Grafana datasource results or populated live panels | `deployment-evidence-pending` | Deployed permanent operator's sanitized, loopback-only access record; baseline smoke does not test them |
| Planned readiness-probe troubleshooting exercise | `deployment-evidence-pending` | Troubleshooting record |
| Optional HPA reconciliation exercise, configuration reapplication, and exact restoration | `deployment-evidence-pending` | HPA drill record plus a subsequent smoke record for exact three-replica restoration; `not-applicable` only when omitted from a completed run |
| Optional application failover exercise, configuration reapplication, and exact restoration | `deployment-evidence-pending` | Failover drill record plus a subsequent smoke record for exact three-replica restoration; `not-applicable` only when omitted from a completed run |
| Guarded teardown, controller cleanup, and residual resources | `deployment-evidence-pending` | Teardown/residual record |
| Guarded two-dispatch HTTPS-to-HTTP transition and certificate-reference proof | `deployment-evidence-pending` | Two linked delivery/DNS-TLS records |
| Redeploy from retained bootstrap/state | `deployment-evidence-pending` | New deployment and smoke records |
| Actual cost and post-teardown dormant spend | `deployment-evidence-pending` | Billing/cost record |

Promote rows independently. A successful deployment does not prove a drill or teardown; a committed dashboard export does not prove runtime Grafana; an empty artifact search does not prove that a future workflow will never expose sensitive data.

# Evidence status

Last account-free validation: 2026-09-04 UTC. One authenticated combined
deployment/drill run and one authenticated teardown run are retained and
summarized in [live-runs.md](live-runs.md). Status is assigned per claim; one
successful workflow does not prove unrelated behavior.

## Status vocabulary

- `verified-account-free`: local/static validation completed successfully; it
  does not establish cloud behavior.
- `observed-live`: an authenticated workflow produced a successful, redacted,
  retrievable result, but the formal independent review record is incomplete.
- `verified-live`: an independent reviewer approved a complete
  [live evidence record](live-evidence-template.md).
- `deployment-evidence-pending`: the claim still needs an authorized live run
  or missing evidence.
- `implementation-deferred`: the repository does not implement the capability.
- `not-applicable`: the capability is optional or outside the selected design.

No current claim is marked `verified-live`; reviewer approval remains a
separate governance step.

## Account-free validation

| Scope | Command/result | Status |
| --- | --- | --- |
| Full repository | `make validate`: Terraform formatting and all three offline validations, Kubernetes rendering/schema checks, Bash/ShellCheck, actionlint, and Grafana JSON parsing passed | `verified-account-free` |
| Relative documentation links | Tracked-Markdown link scan found no missing local targets | `verified-account-free` |
| Sensitive generated artifacts | Tracked-file scan found no plans, state, keys, kubeconfigs, or service-account JSON | `verified-account-free` |
| Grafana export alternative | Three committed dashboard JSON exports parse, including the required overview panels | `verified-account-free` |

## Live status

| Live claim | Current status | Evidence/limit |
| --- | --- | --- |
| Foundation/platform apply through keyless GitHub delivery | `observed-live` | Retained combined deploy run completed; bootstrap creation and least-privilege review remain separate |
| Both clusters `RUNNING` and Fleet memberships `READY` | `observed-live` | Retained smoke report |
| Six Ready replicas per application across both regions | `observed-live` | Retained smoke report records three per app per region |
| MCI VIP, MCS objects, healthy backends, and global HTTP routing | `observed-live` | Retained smoke report; HTTPS is excluded |
| HTTP 200 for `/app-a` and `/app-b` | `observed-live` | Retained smoke report |
| Optional DNS, managed certificate, redirect, and HTTPS | `deployment-evidence-pending` | HTTP-only runs; no owned-domain evidence |
| Cloud Armor attachment | `observed-live` | BackendConfig attachment only; policy enforcement behavior remains pending |
| Workload Identity and Secret Manager runtime boundaries | `deployment-evidence-pending` | No retained least-access or mount evidence |
| BigQuery routed-table schema readiness and seven SQL dry runs | `observed-live` | Retained smoke report; row contents/completeness remain pending |
| Grafana Pod and active dashboard ConfigMap | `observed-live` | Retained smoke report |
| Grafana datasource results or populated panels | `deployment-evidence-pending` | No sanitized interactive record |
| HPA reconciliation and committed-workload restoration | `observed-live` | Combined drill run; next drill's exact baseline precheck confirms three-replica restoration |
| Application-backend failover and workload reapplication | `observed-live` | Five consecutive 200s per route; not a regional-infrastructure outage; exact post-restoration replica count remains pending |
| Planned readiness-probe troubleshooting exercise | `deployment-evidence-pending` | Scenario is documented but not deliberately executed |
| Guarded teardown, controller cleanup, and residual inventory | `observed-live` | Retained teardown report records Kubernetes/multi-cluster cleanup, destroyed platform/foundation stages, removed live controller inventory, and retained state/WIF/deployer/marker anchors |
| Guarded HTTPS-to-HTTP transition | `deployment-evidence-pending` | No retained two-dispatch record |
| Redeploy after retained-state teardown | `deployment-evidence-pending` | Ordinary repeat deployment is proven; post-teardown recovery is not |
| Actual cost and post-teardown dormant spend | `deployment-evidence-pending` | Requires billing evidence after provider lag |

The live workflow reports are intentionally minimal. They do not establish
data quality, security review, production capacity, disaster-recovery
objectives, or cost merely because deployment succeeded.

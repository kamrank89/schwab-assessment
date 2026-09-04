# Architecture walkthrough

This guide gives reviewers a concise path through the implementation, the
decisions behind it, and the evidence that currently exists.

## Architecture in ninety seconds

The platform separates ownership into three Terraform state roots. A
human-run bootstrap creates the versioned GCS backend and repository-scoped,
keyless GitHub identity. Foundation owns shared networking, the ingress
address, Cloud Armor, secrets, centralized log export, and operator IAM.
Platform owns two private regional GKE Autopilot clusters and Fleet
multi-cluster features. Kustomize deploys operator RBAC, App A and App B with
three replicas and CPU HPAs in each region, and Grafana in the primary region.

A reserved global IP fronts Multi Cluster Ingress and Multi Cluster Services.
Path rules send `/app-a` and `/app-b` to healthy Pods across both regions, and
BackendConfigs attach Cloud Armor with full-sample load-balancer logging. HTTP
by IP is the verified baseline; DNS and managed TLS remain optional because no
owned domain was supplied for this assessment run.

GKE workload, node, control-plane, and load-balancer logs flow through Cloud
Logging to partitioned BigQuery tables. The smoke verifier waits for the exact
required table schemas, dry-runs all seven committed SQL files, and checks the
live Grafana Pod plus its three provisioned dashboard exports.

GitHub Actions performs account-free validation before any deployment. Manual
deployment uses short-lived OIDC/WIF credentials, converges the three managed
layers, and runs smoke verification. Optional drills run only after smoke: HPA
first, then application-backend failover. Teardown remains guarded and retains
bootstrap, WIF, and state anchors so a later redeploy is controlled.

## Verified execution path

The retained [live-run summary](evidence/live-runs.md) records one successful
combined deployment/drill run and one successful teardown run on 2026-09-04:

- deployment, smoke verification, exact BigQuery schema readiness, seven SQL
  dry runs, and Grafana readiness;
- HPA reconciliation from three to at least four Ready replicas for both apps
  in `us-central1`, followed by committed-workload restoration; and
- application-backend removal in `us-east1` while both global routes returned
  five consecutive HTTP 200 responses, followed by restoration; and
- guarded Kubernetes and multi-cluster cleanup followed by platform and
  foundation destruction, while retaining the state, WIF, deployer, and
  completion-marker recovery anchors.

These are application-level assessment exercises. They do not prove a regional
infrastructure outage, CPU-driven capacity behavior, an RTO/RPO, populated
Grafana panels, HTTPS, a successful post-teardown redeploy, or cost.

## Repository tour

1. Start with [the architecture overview](architecture/overview.md) and its
   state/traffic diagrams.
2. Review `infra/bootstrap`, `infra/foundation`, and `infra/platform` to see the
   ownership boundaries.
3. Review `k8s/base` and the regional/config overlays to see workload and
   ingress composition.
4. Follow `.github/workflows/deploy.yml` into `scripts/deploy.sh` and
   `scripts/verify.sh` for delivery and evidence flow.
5. Review `observability/bigquery/queries` and the committed Grafana dashboard
   exports for the observability deliverables.
6. Use [requirement traceability](requirements/traceability.md) to distinguish
   implemented, observed-live, deferred, and optional scope.

## Decisions to defend

### Why Autopilot?

It keeps the assessment focused on workloads, identity, routing,
observability, and lifecycle instead of node-pool administration. The trade-off
is request-based billing and reduced node-level control. Production acceptance
would still require representative load and capacity testing.

### Why MCI/MCS instead of multi-cluster Gateway?

MCI/MCS matches the assessment requirement and provides a compact global
routing demonstration. It is deliberate migration debt: production should
move to multi-cluster Gateway API after feature-parity and cutover testing.

### Why one deployment identity?

A single keyless identity makes one-time assessment bootstrap and manual
lifecycle reproducible. Its permissions span multiple layers, increasing blast
radius. Production should split bootstrap, foundation, platform, workload,
verification, and teardown identities and protect them with environment-scoped
subjects and narrower roles.

A separate reviewed Google user receives the supported operator path through
Connect Gateway and Kubernetes RBAC. That path is intentionally powerful for
the assessment and is not presented as production least privilege.

### Why HTTP first?

It verifies the global IP and both routes without pretending an unowned domain
can support valid managed TLS. HTTPS support is implemented but remains
unverified. Returning from HTTPS is deliberately two-step so the ingress stops
referencing the certificate before Terraform may remove certificate and DNS
resources.

### Why digest-pinned public images?

The assessment evaluates platform architecture rather than application build
pipelines. Digest pins make deployed bytes reproducible. They do not prove
publisher provenance, vulnerability posture, tracing, profiling, or rich error
telemetry.

### Why retain bootstrap after teardown?

Destroying the identity and state anchor through the same path that depends on
them is fragile. Retaining the small versioned state bucket, WIF provider, and
deployer enables controlled recovery. Dormant cost is expected to be small,
not guaranteed to be exactly zero.

## Common reviewer questions

- **What proves the workloads are live?** The retained smoke report records
  both clusters `RUNNING`, both Fleet memberships `READY`, and exactly three
  desired and Ready replicas for each application in each region.
- **Was autoscaling tested?** The HPA drill proved controller reconciliation to
  at least four desired and Ready replicas for both apps. It was not a
  CPU-saturation or capacity benchmark.
- **Was failover tested?** The controlled drill removed both application
  Deployments from `us-east1`; both global routes returned five consecutive
  HTTP 200 responses. The cluster remained running, so this is not a full
  regional-outage claim.
- **Is Grafana working?** Smoke proved one Ready Grafana replica and exactly
  three dashboard files in the active ConfigMap. The JSON exports parse, but
  populated datasource panels and interactive login were not recorded.
- **Are the BigQuery queries proven?** Smoke found compatible schemas for
  `stdout`, `requests`, `kubelet`, and
  `container_googleapis_com_apiserver`, then successfully dry-ran all seven
  SQL files. Dry runs do not prove useful row contents or completeness.
- **Was teardown verified?** The retained teardown report records Kubernetes
  and multi-cluster cleanup, destroyed platform and foundation stages, removed
  live controller inventory, and retained state/WIF/deployer recovery anchors.
  Post-teardown redeployment, independent provider-external residual review,
  and billing remain evidence-pending.

## Production follow-ups

1. Split automation identities and replace broad operator access with
   task-specific roles.
2. Migrate MCI to multi-cluster Gateway API.
3. Replace public demos with owned, signed, instrumented applications in a
   private registry.
4. Add SLOs, alerts, budgets, synthetic checks, representative load testing,
   and backup/restore exercises.
5. Tune preview Cloud Armor rules against observed false positives before
   enforcement.

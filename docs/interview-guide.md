# Interview guide

## Ninety-second architecture narrative

“I separated ownership into three Terraform state roots: human-only bootstrap creates a versioned GCS backend and repository-scoped keyless GitHub identity; foundation owns shared network, ingress address, security, secrets, log export, and exact-user operator IAM; platform owns two private regional Autopilot clusters and Fleet multi-cluster features. Kustomize then deploys the exact-user operator RBAC, two applications with three replicas and an HPA baseline in each region, plus recoverable Grafana in the primary cluster.

“A global reserved IP feeds MCI/MCS, which routes `/app-a` and `/app-b` to healthy Pods in both regions and attaches Cloud Armor. HTTP by IP is the safe first verification path; owned DNS and a managed certificate are optional. Logs flow through Cloud Logging into partitioned BigQuery tables, and committed Grafana exports include the four required overview panels.

“Validation is account-free. Deployment and teardown are manual `main` workflows using short-lived OIDC/WIF credentials. HTTPS downgrades use a first dispatch that returns MCI to HTTP and proves the certificate is detached, then an ordinary dispatch may delete certificate/DNS resources. Teardown inventories controller-owned load-balancer resources, deletes in reverse order, and intentionally retains bootstrap/WIF/state so redeploy is simple; it supports both a provably never-created platform and a post-teardown foundation-only partial redeploy whose unchanged empty platform state matches a durable completion marker. I do not claim live results: endpoints, failover, dashboards, queries, IAM, and teardown remain evidence-pending until an authorized, redacted run.”

## Shortest operator story

```text
make tools && make validate
  -> human ADC bootstrap once
  -> configure 13 generated/fixed variables + 1 reviewed operator identity
  -> manual deploy.yml from main, transition/drills false
  -> automatic smoke + evidence collection
  -> guarded teardown.yml with DESTROY <project>
  -> retained bootstrap/state/WIF
  -> manual deploy.yml to recreate
```

## Decisions to defend

### Why Autopilot?

It keeps the assessment on workloads, identity, routing, observability, and lifecycle rather than node-pool operations. The cost and compatibility trade-off is request-based billing plus less node control; production still needs real load/capacity tests.

### Why MCI/MCS instead of Gateway API?

It matches the explicit rubric and provides a concise multi-region global routing demonstration. It is deliberate migration debt: production should move to multi-cluster Gateway API after feature-parity and cutover testing.

### Why one deployer identity?

It makes one-time assessment bootstrap and manual lifecycle reproducible without keys. Its broad permissions increase blast radius. Production should separate bootstrap, foundation, platform, workload, verifier, and teardown identities with protected Environment subjects and narrow roles.

The single deployer describes automation only. A separate, reviewed Google user is declaratively granted permanent Connect Gateway, Kubernetes `cluster-admin`, and secret-scoped Grafana password access; the supported helper keeps Grafana private behind a sanitized loopback-only port-forward. This is intentionally a super-user operator path, not production least privilege.

### Why HTTP first?

It verifies the global IP and both routes without requiring ownership/delegation of a domain. Managed TLS cannot be honestly verified until public DNS points an owned hostname at the load balancer. HTTP is an assessment baseline, not the production security endpoint.

Returning from HTTPS is deliberately two-dispatch: the guarded first run makes only the HTTP MCI/controller change and proves no target HTTPS or SSL proxy references the managed certificate; the second ordinary run may then remove Terraform certificate/DNS resources. This sequencing avoids asking Google to delete a still-referenced certificate.

### Why digest-pinned public images?

The assessment evaluates platform architecture, not a custom application build. Digest pins make bytes reproducible, while the limitations explicitly state they do not prove provenance, vulnerabilities, Trace, Profiler, or rich error telemetry.

### Why retain bootstrap after teardown?

Destroying the identity and state anchor in the same path that needs them is fragile. Retaining a tiny versioned state bucket, WIF, and deployer makes recovery/redeploy controlled. Dormant spend is expected to be negligible, not guaranteed literal $0.

## Evidence answers

- **What is verified now?** Only the account-free commands recorded in `docs/evidence/status.md`.
- **What proves six replicas?** A future smoke report showing three desired/Ready/updated/available App A and App B replicas in each of two regions.
- **Is failover tested?** No. The repository has a bounded application-backend exercise with restoration traps; it remains pending until deliberately run.
- **Is Grafana working?** Three JSON exports parse and are committed, and the permanent operator/loopback access path is implemented account-free; live Pod/datasource/panel access is still pending an authorized deployment and redacted record.
- **Are the BigQuery queries proven?** Their source is reviewed; future smoke first waits for the four exact routed tables and compatible top-level schema, then dry-runs all seven. Useful rows and results are still live evidence.
- **Did teardown leave nothing?** No teardown has run, and normal teardown intentionally retains bootstrap state/WIF/deployer plus empty state and its completion marker. A residual record must distinguish destroyed, already-empty, and both skipped-stage proofs from retained anchors. Historical-only or soft-deleted-only state is a recovery stop, not proof that a stage never existed.

## Likely follow-up improvements

1. Split identities and add protected GitHub Environments after updating exact WIF subjects.
2. Migrate MCI to multi-cluster Gateway API.
3. Replace public demos with owned, signed, instrumented applications and a private registry.
4. Add SLOs, alerts, budgets, load/failure tests, data backup/restore, and production evidence retention.
5. Tune Cloud Armor preview rules and enforce them only after observing false positives.

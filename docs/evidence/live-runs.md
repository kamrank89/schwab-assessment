# Retained live runs

Exactly two authenticated GitHub Actions runs are retained as automated live
evidence: one combined deployment/drill run and one guarded teardown run.
Their redacted reports contain statuses and counts only; they omit response
bodies, credentials, secrets, kubeconfigs, Terraform plans/state, BigQuery
rows, and schema payloads.

The combined run used commit
`3c8dc3e583159db019327dd0e7da87e76c382cab`. Repository history was
subsequently consolidated; deployment commit
`a9b6a0b0b017f9b4353a4273d6c9e9137dde1a73` has the identical Git tree
`63d9d09650f1a1b9d162cda236769aa6ed3468b2`. The teardown ran that
consolidated deployment commit. Later documentation-only amendments changed
provenance presentation, not the deployed files.

## Deployment, smoke, HPA, and failover

- Run: [33821149199](https://github.com/kamrank89/schwab-assessment/actions/runs/33821149199)
- Result: successful
- Smoke window: 2026-09-04 00:21:05–00:21:48 UTC
- HPA window: 2026-09-04 00:22:40–00:25:22 UTC
- Failover window: 2026-09-04 00:26:10–00:27:02 UTC
- Retention: GitHub-hosted reports retained according to the workflow's
  seven-day artifact policy

The smoke result repeated the deployment assertions above. The HPA exercise
reconciled App A and App B in `us-central1` to at least four desired and Ready
replicas and successfully reapplied committed workloads. The next gated drill
then established the exact three-replica baseline in both regions before
continuing. The failover exercise removed both app Deployments from
`us-east1`; `/app-a` and `/app-b` each returned five consecutive HTTP 200
responses, after which committed workloads were reapplied and rollouts
completed.

## Guarded teardown

- Run: [33822399015](https://github.com/kamrank89/schwab-assessment/actions/runs/33822399015)
- Result: successful
- Report timestamp: 2026-09-04 00:48:39 UTC
- Retention: GitHub-hosted report retained according to the workflow's
  seven-day artifact policy

The report records Kubernetes and multi-cluster cleanup as completed or
already absent, then records both the platform and foundation stages as
destroyed. It also records the intentionally retained versioned state bucket,
bootstrap state, WIF provider, and deployer identity. The completion marker was
persisted and bound to the exact empty platform state before the live
controller recovery inventory was removed; the final report confirms that the
live inventory was removed and the marker remained active for that state.

## Evidence status and limits

These results are `observed-live`: an authenticated automated run and redacted
artifact exist, but an independent reviewer has not completed the
[live evidence template](live-evidence-template.md). They do not prove:

- HTTPS, managed-certificate, or DNS behavior;
- a cluster, zone, control-plane, or full regional outage;
- CPU-driven scaling, production capacity, latency objectives, RTO, or RPO;
- useful BigQuery row contents, logging completeness, or populated Grafana
  panels;
- secret-value access boundaries or broad IAM least privilege;
- a successful redeploy after teardown, provider-external residual inspection
  beyond the workflow report, or actual cost.

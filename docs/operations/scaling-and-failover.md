# Controlled scaling and failover exercises

Both exercises are optional, application-scoped, mutating, bounded to ten minutes, and protected by restoration traps. They are disabled by default and must follow a successful smoke run. Neither proves a control-plane outage, zone outage, full cluster disaster, capacity under load, or an RTO/RPO.

## HPA reconciliation exercise

Dispatch only HPA:

```bash
# CLOUD/KUBERNETES MUTATION and temporary cost: raises both apps to four replicas in us-central1.
gh workflow run deploy.yml --ref main \
  -f https_to_http_transition=false \
  -f run_hpa_drill=true \
  -f run_failover_drill=false
```

The workflow invokes:

```bash
./scripts/verify.sh hpa --region us-central1 --confirm "HPA us-central1"
```

The script verifies the healthy three-replica baseline, temporarily patches both HPA `minReplicas` to 4, waits for four Ready replicas, then reapplies the committed regional overlay and waits for both Deployment rollouts. Its restoration record proves configuration reapplication and rollout completion, not the exact post-restoration replica state. Run a subsequent `./scripts/verify.sh smoke` or rerun the deploy workflow before claiming the exact three desired/Ready/updated/available replicas. The exercise proves HPA controller reconciliation, not CPU-driven autoscaling under load. The extra Pods add temporary Autopilot and MCI backend-Pod cost.

## Application failover exercise

Dispatch only failover:

```bash
# CLOUD/KUBERNETES MUTATION: temporarily deletes both app Deployments in us-east1.
gh workflow run deploy.yml --ref main \
  -f https_to_http_transition=false \
  -f run_hpa_drill=false \
  -f run_failover_drill=true
```

The workflow invokes:

```bash
./scripts/verify.sh failover --region us-east1 --confirm "FAILOVER us-east1"
```

The script first establishes a healthy three-replica baseline, deletes only App A and App B Deployments in the chosen region, and requires five consecutive successful checks of both global routes. Its armed trap reapplies the committed overlay and waits for both Deployment rollouts after a catchable interruption. That restoration record proves configuration reapplication and rollout completion; a subsequent `./scripts/verify.sh smoke` or deploy-workflow rerun is required before claiming the exact three desired/Ready/updated/available replicas.

Call this a controlled application-backend failover exercise. The cluster remains running and other resources remain present; it is not evidence of regional infrastructure failure.

## Combined dispatch and evidence

If both booleans are true, HPA runs before failover. Run one at a time for clearer evidence unless a reviewed test plan requires the sequence. Before execution define stop conditions, observers, expected codes, and the restoration owner. Afterward capture the redacted drill report, workflow URL, UTC times, commit, actor/reviewer, and configuration-reapplication result. Attach the subsequent smoke record separately before claiming exact three-replica restoration. A drill row remains `deployment-evidence-pending` until both required records exist.

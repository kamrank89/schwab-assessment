# Rollout and rollback

## Normal rollback: source first

Terraform and Kustomize are the desired-state sources. The durable rollback is a reviewed revert on `main`, followed by the normal manual deployment:

```bash
# SOURCE-CONTROL MUTATION only; create a reviewed revert branch/PR.
git revert <bad-commit-sha>
```

After the revert passes the required `validate` check and merges to protected `main`:

```bash
# CLOUD MUTATION and cost: converges Terraform and Kubernetes to the reverted source.
gh workflow run deploy.yml --ref main \
  -f run_hpa_drill=false \
  -f run_failover_drill=false
```

Record the failed commit, reverted commit, approval, workflow URLs, affected resources, and post-rollback smoke result. Never copy a saved plan between runs; each stage creates and applies its own same-job plan.

## Workload rollout diagnosis

With a fresh Connect Gateway kubeconfig, inspect before mutating:

```bash
# LIVE READ ACCESS.
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment get deployments,pods,hpa
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment rollout status deployment/app-a --timeout=10m
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment describe deployment/app-a
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment get events --sort-by=.lastTimestamp
```

The manifests use rolling updates with `maxSurge: 1` and `maxUnavailable: 0`, PDBs with `minAvailable: 2`, readiness/startup/liveness probes, and topology spreading. Determine whether the failure is image pull, scheduling, probe, CSI mount, quota, policy, or application behavior before choosing a rollback.

## Emergency rollout undo

Only under an approved incident, a cluster-local rollback may reduce time to recovery:

```bash
# CLOUD/KUBERNETES MUTATION; emergency and not durable desired state.
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment rollout undo deployment/app-a
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment rollout status deployment/app-a --timeout=10m
```

Repeat separately for App B or the other region only when evidence identifies it as affected. Then revert/fix the repository and run the normal deployment; otherwise the next deployment can reintroduce the bad revision. Do not use ad hoc Terraform state edits or direct deletion as rollback.

## Infrastructure failure

If a Terraform apply is interrupted, inspect the workflow and remote state, then rerun the same stage through the full deploy workflow. The scripts fail closed on unexpected state. If a partial environment must be removed, use the guarded [teardown](../setup/teardown.md), not `terraform destroy` from a root by hand.

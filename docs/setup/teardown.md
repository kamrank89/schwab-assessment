# Guarded teardown and redeploy

Teardown is manual, destructive, and serialized with deployment. It must run from `main`, the dispatched project must exactly equal `GCP_PROJECT_ID`, and the confirmation must be literal `DESTROY <project-id>`.

## Preflight

- Stop application changes and ensure no deploy run shares the `assessment-production` concurrency group.
- Capture required evidence and the serving commit SHA; never save plans, state, kubeconfigs, tokens, passwords, or secret values.
- Identify external DNS records or registrar delegation not owned by Terraform.
- Review the billable-resource inventory and version-aware remote-state health. A live state generation is distinct from noncurrent history.
- Obtain the recommended independent `teardown` approval.

## Dispatch

```bash
# DESTRUCTIVE CLOUD MUTATION: deletes application and infrastructure resources.
gh workflow run teardown.yml --ref main \
  -f project_id=example-project \
  -f confirmation='DESTROY example-project'
```

The normal path inventories the exact MCI controller-owned forwarding rules, proxies, URL map, health checks, backend services, and firewall rules before deletion and persists a recovery inventory in the state bucket. It deletes MCI/MCS and workloads first, waits up to 30 minutes for every inventoried load-balancer resource to disappear, removes regional namespaces/access RBAC, then creates and applies same-file destroy plans for platform followed by foundation. It refuses the bootstrap root.

The supported partial-deployment exception is foundation-only recovery. Version-aware object listing must find one live foundation state and no live or noncurrent `platform/default.tfstate`; both exact supported clusters and the local controller recovery inventory must be absent, and the exact durable inventory must have no live or noncurrent generation. Only then does the script skip Kubernetes/controller cleanup and the platform destroy, and destroy (or recognize as already empty) the bound foundation state. The report records each cleanup/stage as `skipped-platform-never-created`, `destroyed`, or `already-empty` rather than claiming every stage was deleted.

If interrupted, rerun the same guarded teardown after inspecting the persisted inventory and state. Do not manually delete the state bucket or discard inventory to force progress. The script validates state lineage, serial, content binding, live generation, and expected ownership before evaluating a destroy plan. A state object with noncurrent generations but no live generation is classified as lost state and stops. Likewise, absent platform state plus either supported cluster or any controller inventory stops before mutation. Restore the exact live state/inventory or perform a separately reviewed manual recovery; deleting history is not a way to manufacture the supported foundation-only case.

## Intentionally retained

Normal teardown retains:

- the existing GCP project;
- bootstrap/default Terraform state and any empty/current foundation/platform state objects and versions that were created;
- the versioned state bucket;
- the GitHub WIF pool/provider and repository trust;
- `assessment-deployer` and bootstrap IAM bindings; and
- bootstrap APIs, because their Terraform resources set `disable_on_destroy=false`.

This is the redeploy anchor. Storage for tiny state objects and occasional operations is normally negligible, and idle IAM/WIF objects do not run compute, but “effectively zero dormant cost” is not a mathematical $0 guarantee. Check the billing report and current [Cloud Storage pricing](https://cloud.google.com/storage/pricing). Removing bootstrap is a separate, high-risk decommissioning project requiring identity/state migration and is not implemented by `teardown.sh`.

## Redeploy

After the teardown report and residual check are recorded, use the same manual deploy command:

```bash
# CLOUD MUTATION and cost: recreates foundation, platform, workloads, and routing from retained state.
gh workflow run deploy.yml --ref main \
  -f https_to_http_transition=false \
  -f run_hpa_drill=false \
  -f run_failover_drill=false
```

Do not rerun human bootstrap unless the bootstrap itself is absent or intentionally changed. Record redeploy smoke evidence as a new live record, not an amendment to the old deployment.

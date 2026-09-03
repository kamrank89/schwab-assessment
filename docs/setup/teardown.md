# Guarded teardown and redeploy

Teardown is manual, destructive, and serialized with deployment. It must run from `main`, the dispatched project must exactly equal `GCP_PROJECT_ID`, and the confirmation must be literal `DESTROY <project-id>`.

## Preflight

- Stop application changes and ensure no deploy run shares the `assessment-production` concurrency group.
- Capture required evidence and the serving commit SHA; never save plans, state, kubeconfigs, tokens, passwords, or secret values.
- Confirm the required `GCP_CLUSTER_ADMIN_EMAIL` repository variable still names the operator whose Terraform grant will be destroyed. The script validates that single input, rejects a differing nonempty `TF_VAR_cluster_admin_email`, and exports its normalized value before any lifecycle inspection or mutation.
- Identify external DNS records or registrar delegation not owned by Terraform.
- Review the billable-resource inventory and version-aware remote-state health. Live, noncurrent, and soft-deleted generations are distinct evidence classes.
- Obtain the recommended independent `teardown` approval.

## Dispatch

```bash
# DESTRUCTIVE CLOUD MUTATION: deletes application and infrastructure resources.
gh workflow run teardown.yml --ref main \
  -f project_id=example-project \
  -f confirmation='DESTROY example-project'
```

The normal path inventories the exact MCI controller-owned forwarding rules, proxies, URL map, health checks, backend services, and firewall rules before deletion and persists a recovery inventory in the state bucket. Before mutation, every recoverable generation of that exact inventory object must be either the validated live generation or chained through the prior live teardown-completion marker. It deletes MCI/MCS and workloads first, waits up to 30 minutes for every inventoried load-balancer resource to disappear, removes regional namespaces/access RBAC, then creates and applies same-file destroy plans for platform followed by foundation. It refuses the bootstrap root.

There are two supported foundation-only recovery proofs:

- **Genuinely never created:** one live foundation state exists; `platform/default.tfstate`, the exact durable controller inventory, and the exact completion marker have no live, noncurrent, or soft-deleted generation; neither supported cluster nor the local inventory exists. The script records `skipped-platform-never-created` / `skipped-never-created` and destroys (or recognizes as already empty) the independently bound foundation state.
- **Prior teardown completed, then foundation was partially recreated:** one live foundation state exists; the exact live platform state is valid and empty; neither supported cluster nor a live local/durable inventory exists; and a live completion marker matches the platform object's generation, lineage, serial, and canonical content digest. Any recoverable inventory generation must be in the marker's exact generation set. The script records `skipped-platform-completion-bound` / `skipped-completion-bound-empty`, leaves that exact empty platform state untouched, and destroys the current independently bound foundation state.

The marker is `recovery/teardown-completion-<project-id>.json` in the retained state bucket. Only a strict normal teardown can create or replace it: controller inventory cleanup must have completed, both Terraform states must be valid and empty, both clusters must be absent, and the live inventory plus its complete recoverable generation set must be verified. The marker records both state bindings and the validated inventory identity. It is written with a destination-generation precondition while the live inventory still exists, then becomes usable only after that exact inventory generation is conditionally removed and absence is reverified. This ordering leaves a usable inventory if marker persistence fails and makes a marker harmless if inventory removal fails. The state bucket can retain the removed generation as noncurrent or soft-deleted history; only generations already chained into the live marker are accepted.

If interrupted, rerun the same guarded teardown after inspecting the persisted inventory, marker, and state. Do not manually delete the state bucket or discard either durable record to force progress. Exact-object discovery separately lists live/noncurrent and soft-deleted generations with exhaustive soft-delete pagination; a command, access/API, malformed-data, duplicate-identity, or concurrent-transition failure is never absence. A state object with only noncurrent or soft-deleted generations is lost state and stops. Absent platform state plus any cluster, inventory generation, or marker generation also stops. An empty platform state with an absent, historical-only, malformed, stale, or mismatched live marker cannot use the shortcut. Restore the exact live state/inventory/marker or perform a separately reviewed manual recovery; deleting history is not a way to manufacture either supported exception.

## Intentionally retained

Normal teardown retains:

- the existing GCP project;
- bootstrap/default Terraform state and any empty/current foundation/platform state objects and versions that were created;
- the versioned state bucket;
- the live teardown-completion marker after a successful normal teardown, plus state-bucket-retained inventory/marker history;
- the GitHub WIF pool/provider and repository trust;
- `assessment-deployer` and bootstrap IAM bindings; and
- bootstrap APIs, because their Terraform resources set `disable_on_destroy=false`.

The live controller recovery inventory is removed after successful normal teardown; Object Versioning and soft delete can retain recoverable generations in the bucket. The completion marker makes those exact generations auditable without retaining an active inventory that would conflict with a later MCI UID/resource set.

These objects are the redeploy anchor. Storage for tiny state objects and occasional operations is normally negligible, and idle IAM/WIF objects do not run compute, but “effectively zero dormant cost” is not a mathematical $0 guarantee. Check the billing report and current [Cloud Storage pricing](https://cloud.google.com/storage/pricing). Removing bootstrap is a separate, high-risk decommissioning project requiring identity/state migration and is not implemented by `teardown.sh`.

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

If this redeploy fails after foundation changes but before platform state mutation, the completion-bound foundation-only path is supported because the exact empty platform binding is unchanged. Once a deploy mutates platform state, the prior marker is stale and cannot authorize a shortcut; teardown must use the live MCI/controller inventory path and replaces the marker only after strict cleanup succeeds.

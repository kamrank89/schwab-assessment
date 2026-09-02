# Manual deployment

Deployment is never automatic. `.github/workflows/deploy.yml` accepts only a manual dispatch on `main` and runs account-free validation first. Its ordinary path deploys foundation, platform/workloads, and smoke verification. The guarded `https_to_http_transition` mode and the optional HPA and application-failover exercises all default to `false`; transition mode rejects either drill.

## Configure variables

Start with the HTTP baseline configured by bootstrap:

```text
GCP_ENABLE_HTTPS=false
GCP_MANAGE_DNS=false
GCP_CREATE_DNS_ZONE=false
GCP_DNS_NAME=
GCP_DNS_ZONE_NAME=
GCP_DNS_ZONE_DNS_NAME=
```

Review all 13 values in repository settings before dispatch. Regions are fixed to `us-central1` and `us-east1`; the scripts reject other values. For HTTPS, use the exact combinations in [DNS/TLS](dns-tls.md).

## Dispatch the baseline

```bash
# CLOUD MUTATION and cost: foundation, clusters, workloads, MCI/LB, logging, observability.
gh workflow run deploy.yml --ref main \
  -f https_to_http_transition=false \
  -f run_hpa_drill=false \
  -f run_failover_drill=false
```

In the GitHub UI, choose **Actions → deploy → Run workflow**, select `main`, and leave the transition and both drill boxes clear. Record the workflow URL and commit SHA before collecting evidence.

The workflow order is:

```text
make validate
  -> foundation same-job plan/apply
  -> platform same-job plan/apply
  -> namespaces/RBAC/workloads/MCI-MCS
  -> smoke verification, exact BigQuery schema readiness, and seven SQL dry runs
  -> optional HPA exercise
  -> optional application-failover exercise
```

Terraform native plan output is suppressed; the scripts print only resource addresses and action types, apply the same mode-0600 temporary plan, and remove it through traps. Workload deployment creates ephemeral kubeconfigs, renders into ignored `.generated/k8s`, creates initial random App A/Grafana secret versions only if absent, waits on rollouts/MCI, and removes kubeconfigs. No plan or kubeconfig is uploaded.

An HTTPS deployment must return to HTTP through two dispatches. First set all HTTPS/DNS booleans false and clear the DNS strings, then dispatch with `https_to_http_transition=true` and both drills false. That path skips foundation/platform Terraform mutation, applies only the HTTP MCI overlay, waits for its VIP and both HTTP routes, and succeeds only after both MCI TLS/frontend annotations are absent and no target HTTPS or SSL proxy references the managed certificate. After it succeeds, dispatch the ordinary command above; only that second run may remove the Terraform certificate/DNS resources and continue through normal smoke. See [DNS/TLS](dns-tls.md) for exact commands and mutation/cost labels.

## Cost and failure behavior

Foundation creation can start charges for static IP, Cloud NAT, Cloud Armor, BigQuery/Logging, Secret Manager, and optional DNS/TLS. Platform creates two billable Autopilot clusters. MCI adds standalone backend-Pod pricing plus controller-created load-balancer charges. Workload requests, traffic, logging, and queries are usage-billed. Review [cost assumptions](../cost.md) before dispatch.

Jobs are ordered and use remote state, so rerunning the workflow is the supported convergence path after correcting an issue. Do not bypass a failed stage with ad hoc applies. A partial successful foundation/platform remains billable until the next successful deploy or guarded teardown; inspect state and workflow logs without exposing sensitive output. Guarded teardown supports the exact foundation-only case when the foundation live state exists and version-aware discovery proves that platform state was never created, both supported clusters are absent, no local controller recovery inventory exists, and the exact durable inventory has no live or noncurrent generation. Historical-only platform state or any cluster/inventory evidence is a lost-state stop, not an absent-stage shortcut.

After success, follow [verification](../operations/verification.md) and [evidence collection](../evidence/checklist.md). A green workflow has not occurred in this repository yet; it remains `deployment-evidence-pending`.

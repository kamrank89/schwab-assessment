# IAM and secrets

## Identity layers

```text
Human ADC (bootstrap only)
  -> GitHub OIDC/WIF subject restricted to immutable repository + owner IDs + main
    -> assessment-deployer GSA (all manual lifecycle jobs)
      -> IAM-authorized GKE DNS endpoint for initial RBAC
      -> Fleet Connect Gateway + narrow Kubernetes RBAC for routine operations

GKE Workload Identity
  -> assessment/app-a KSA -> app-a-runtime GSA -> app-a-demo secret only
  -> observability/grafana KSA -> grafana-runtime GSA
       -> grafana-admin secret, assessment_logs read/job use, Monitoring read
  -> assessment/app-b KSA -> no GSA annotation, automount token disabled
```

The assessment deployer deliberately spans foundation, platform, workload, verification, and teardown permissions, including administrative GKE/Fleet, Compute, BigQuery, DNS, logging, Secret Manager, service usage, and selected IAM roles plus state-bucket access. This makes a compact assessment bootstrap but not least privilege by production standards. See [ADR 0003](../adr/0003-single-oidc-identity.md) for required future separation.

Optional Dev/Ops/SRE principal lists exist in foundation Terraform and default to empty. Their reviewed role groupings are code, not evidence that any team principal was granted access.

## Keyless policy

- Use WIF for GitHub and Workload Identity Federation for GKE for Pods.
- Never create a user-managed service-account key for deployment or workloads.
- Never store cloud credentials, secret values, Terraform state, plans, or kubeconfigs in GitHub variables, secrets, logs, summaries, or artifacts.
- Keep `id-token: write` only on privileged manual jobs; validation has only `contents: read`.
- Authenticate human bootstrap with ADC and keep it outside GitHub Actions.

Google recommends WIF for external deployment pipelines and immutable numeric GitHub identifiers reduce name-reuse risk; see [Google's deployment-pipeline guide](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines).

## Runtime secrets

Terraform creates secret containers only. During workload deployment, the script checks for an enabled version and, only if none exists, pipes 48 random bytes from `openssl` into `gcloud secrets versions add --data-file=-`. The value never enters Terraform, a file, an argument, or output.

App A and Grafana mount `versions/latest` as read-only files through `secrets-store-gke.csi.k8s.io`. GKE secret rotation is enabled at a five-minute interval. This avoids Kubernetes Secret objects but does not eliminate rotation design: applications must safely reread or restart when needed, versions need a retention/disable/destroy policy, and access should be audited.

Runtime secret behavior is live-only. Static manifests prove intended identity and mount wiring, not successful IAM evaluation or readable files. Verify existence and file permissions without printing content, and record only a redacted pass/fail result.

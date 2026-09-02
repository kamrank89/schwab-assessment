# Multi-region GKE assessment

This repository is a deploy-ready, Terraform- and Kustomize-based assessment implementation for two regional GKE Autopilot clusters, two three-replica web applications, global Multi Cluster Ingress, Cloud Armor, Secret Manager, BigQuery log analysis, and Grafana.

No Google Cloud deployment has been run from this repository. Account-free checks are recorded separately from live evidence in [evidence status](docs/evidence/status.md); every cloud-dependent result remains `deployment-evidence-pending` until an authorized run is recorded with the [live evidence template](docs/evidence/live-evidence-template.md).

## Shortest safe operator path

1. Install the pinned local tools and validate without an account:

   ```bash
   make tools
   make validate
   ```

2. Install Google Cloud CLI 582.0.0, including `gke-gcloud-auth-plugin` and `bq`, and gather the prerequisites in [docs/setup/prerequisites.md](docs/setup/prerequisites.md).

3. As a human with Application Default Credentials, perform the one-time bootstrap against an existing project. **Cloud mutation: enables APIs and creates the state bucket, GitHub WIF provider, IAM grants, and `assessment-deployer`; billing can begin.**

   ```bash
   gcloud auth application-default login
   make bootstrap \
     PROJECT_ID=example-project \
     STATE_BUCKET=example-project-tfstate \
     GITHUB_REPOSITORY=OWNER/REPO \
     GITHUB_OWNER_ID=123 \
     GITHUB_REPOSITORY_ID=456
   ```

4. Configure the 13 non-secret GitHub repository variables. Bootstrap attempts this automatically when `gh` is authenticated; the explicit rerun is:

   ```bash
   make configure-github-variables \
     GITHUB_REPOSITORY=OWNER/REPO \
     OUTPUTS_FILE=.generated/bootstrap-outputs.json
   ```

5. Protect `main` and review the [GitHub governance checklist](docs/setup/github.md), then dispatch the HTTP baseline from `main`. **Cloud mutation: creates billable foundation, platform, workload, load-balancer, logging, and observability resources.**

   ```bash
   gh workflow run deploy.yml --ref main \
     -f https_to_http_transition=false \
     -f run_hpa_drill=false \
     -f run_failover_drill=false
   ```

   The workflow validates, deploys foundation, deploys platform and workloads, then runs smoke verification. DNS is not needed for this HTTP/IP path. See [deployment](docs/setup/deployment.md), [verification](docs/operations/verification.md), and the optional [DNS/TLS path](docs/setup/dns-tls.md).

6. Collect and redact evidence according to the [post-deployment checklist](docs/evidence/checklist.md). Do not change a live row to `verified-live` without a complete evidence record.

7. Tear down in reverse order. **Destructive cloud mutation: deletes assessment workloads, MCI/MCS and controller resources, clusters, and foundation resources.**

   ```bash
   gh workflow run teardown.yml --ref main \
     -f project_id=example-project \
     -f confirmation='DESTROY example-project'
   ```

   Bootstrap state, its versioned state bucket, WIF provider, enabled bootstrap APIs, project, IAM bindings, and `assessment-deployer` are intentionally retained. Dormant cost should be tiny for a small state object, but is not guaranteed to be literal mathematical $0; see [cost](docs/cost.md) and [teardown](docs/setup/teardown.md).

8. Redeploy with the same manual deploy command. The retained bootstrap and remote state boundary make this a normal recreate, not a second bootstrap.

## Documentation map

- [Architecture overview](docs/architecture/overview.md)
- [Delivery and identity](docs/architecture/delivery-and-identity.md)
- [Traffic and observability](docs/architecture/traffic-and-observability.md)
- [Assessment traceability](docs/requirements/traceability.md)
- [Setup and deployment](docs/setup/prerequisites.md)
- [Operations and troubleshooting](docs/operations/troubleshooting.md)
- [Security posture and limitations](docs/security/limitations.md)
- [Cost assumptions and controls](docs/cost.md)
- [Evidence status](docs/evidence/status.md)
- [Interview guide](docs/interview-guide.md)

The assessment's supplied source is preserved byte-for-byte at [docs/requirements/assessment-source.md](docs/requirements/assessment-source.md).

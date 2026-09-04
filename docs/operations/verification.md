# Verification and evidence

## Account-free verification

```bash
# No account, authentication, cloud mutation, or live evidence.
make validate
git diff --check
find . -type f \( -name '*.tfplan' -o -name '*.tfstate' -o -name '*.pem' -o -name '*service-account*.json' -o -name 'kubeconfig*' \) \
  -not -path './.git/*' -print
```

The expected sensitive-artifact search output is empty. These checks prove syntax, formatting, recognized schemas, workflow lint, and JSON validity only. They cannot prove IAM, state locking, cluster/Fleet readiness, MCI reconciliation, endpoints, certificate state, Secret Manager mounts, logs, Grafana health, failover, HPA behavior, teardown, or cost.

## Normal smoke verification

The manual `deploy.yml` workflow always runs this exact authenticated command after deployment:

```bash
# LIVE READ/QUERY activity; no intended cloud mutation, but BigQuery/API usage can be billed.
./scripts/verify.sh smoke
```

Required environment: `GCP_PROJECT_ID`, `GCP_PROJECT_NUMBER`, `GCP_DEPLOYER_SERVICE_ACCOUNT`, `GCP_CLUSTER_ADMIN_EMAIL`, `TF_STATE_BUCKET`, and `GCP_ENABLE_HTTPS`; add `GCP_DNS_NAME` when HTTPS is enabled. The workflow supplies them from repository variables and authenticates as `assessment-deployer` through WIF.

Smoke checks:

- both exact clusters are `RUNNING` and both Fleet memberships are `READY`;
- App A and App B each have exactly three desired/Ready/updated/available replicas in each region and successful rollouts;
- the MCI VIP equals Terraform's reserved address, exactly two MCS objects exist, both BackendConfigs reference the Cloud Armor policy, and every reported backend status is `HEALTHY`;
- HTTP/IP 2xx for both routes, or HTTP 3xx plus `ACTIVE` certificate and HTTPS 2xx when enabled;
- the metadata-only BigQuery readiness loop finds exact `stdout`, `requests`, `kubelet`, and `kube_apiserver` tables with compatible required top-level columns before all seven SQL files pass a Standard SQL dry run, with one-hour bounded parameters for data queries; and
- Grafana is one Ready replica whose current Deployment-referenced dashboard ConfigMap has exactly the three expected JSON exports.

The script writes a mode-0600 redacted report under `artifacts/live/smoke-<UTC>.txt`; GitHub retains the uploaded report for seven days. It deliberately omits response bodies, query rows, schema-discovery payloads, tokens, secrets, state, plans, and kubeconfigs. A workflow log/report is supporting evidence, not a substitute for the complete metadata required by [live-evidence-template.md](../evidence/live-evidence-template.md).

## Endpoint spot checks

After smoke has supplied the actual address, these are read-only client checks; discard bodies if they might contain data:

```bash
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  "http://GLOBAL_IPV4/app-a"
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  "http://GLOBAL_IPV4/app-b"
```

For HTTPS, use the owned hostname and expect HTTP 3xx then HTTPS 2xx. Record UTC time, commit, actor, command, status class, and artifact location; do not record application bodies.

## Grafana access boundary

Smoke verification proves only that the health-probe-gated Grafana Pod is Ready and the exact hash-suffixed ConfigMap named by its current `dashboards` volume contains the three expected dashboard JSON keys. It deliberately ignores stale generated maps left by earlier applies. The three committed JSON exports, including the four required overview panels, satisfy the assessment's export alternative without a live login.

For an authorized permanent cluster administrator, use the local-only access helper. It requires the active `gcloud` account to be the same user email supplied to it, rejects credential/access-token and service-account-impersonation overrides, forces Application Default Credentials off, and pins that account for Gateway credential generation and kubectl authentication:

```bash
read -rp 'Cluster administrator Google email: ' GCP_CLUSTER_ADMIN_EMAIL
./scripts/access-grafana.sh \
  --project-id assessment-507423 \
  --operator-email "${GCP_CLUSTER_ADMIN_EMAIL}"
```

Browse to `http://127.0.0.1:3000` and sign in with username `admin`. In a separate local terminal, retrieve the password directly from Secret Manager only after repeating the same fail-closed exact-user checks. The checks capture configured override values only in shell variables and never print them:

```bash
(
  set -euo pipefail
  set +x

  read -rp 'Cluster administrator Google email: ' GCP_CLUSTER_ADMIN_EMAIL
  [[ "${GCP_CLUSTER_ADMIN_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || {
    printf '%s\n' 'ERROR: Invalid cluster administrator email.' >&2
    exit 1
  }
  expected_operator="${GCP_CLUSTER_ADMIN_EMAIL,,}"

  for variable_name in \
    CLOUDSDK_AUTH_ACCESS_TOKEN \
    CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
    CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
    CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT; do
    [[ -z "${!variable_name+x}" ]] || {
      printf '%s\n' 'ERROR: Google Cloud credential override environment variables must be unset.' >&2
      exit 1
    }
  done

  for property_name in \
    auth/access_token_file \
    auth/credential_file_override \
    auth/impersonate_service_account; do
    if ! property_value="$(gcloud config get-value "${property_name}" 2>/dev/null)"; then
      printf '%s\n' 'ERROR: Could not verify the active gcloud credential configuration.' >&2
      exit 1
    fi
    [[ -z "${property_value}" || "${property_value}" == "(unset)" ]] || {
      printf '%s\n' 'ERROR: Google Cloud credential override properties must be unset.' >&2
      exit 1
    }
  done

  if ! active_account="$(
    gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null
  )"; then
    printf '%s\n' 'ERROR: Could not verify the active gcloud account.' >&2
    exit 1
  fi
  [[ "${active_account}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ &&
    "${active_account,,}" == "${expected_operator}" ]] || {
    printf '%s\n' 'ERROR: The active gcloud account does not match the expected operator.' >&2
    exit 1
  }

  CLOUDSDK_CORE_ACCOUNT="${expected_operator}" \
  CLOUDSDK_CONTAINER_USE_APPLICATION_DEFAULT_CREDENTIALS=false \
    gcloud secrets versions access latest \
      --secret=grafana-admin \
      --project=assessment-507423 \
      --account="${expected_operator}"
)
```

Stop the forward with Ctrl-C when finished. Never paste the password or dashboard data into tickets, logs, artifacts, or Git. This is a permanent `cluster-admin` path, not least-privilege UI access; it includes all resources, Secrets, and authorization mutation in both clusters. See [IAM and secrets](../security/iam-and-secrets.md#permanent-operator-and-revocation) for identity and revocation requirements.

## Optional exercises

HPA and application failover are excluded from normal smoke and run only when deliberately selected. Follow [scaling and failover](scaling-and-failover.md); do not describe either as executed until its restoration and evidence record are complete.

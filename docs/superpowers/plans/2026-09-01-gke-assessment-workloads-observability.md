# GKE Assessment Workloads and Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build hardened, digest-pinned Kustomize workloads for two regions, rubric-aligned MCI/MCS traffic resources, internal Grafana provisioning with three dashboards, bounded BigQuery queries, and an account-free readiness troubleshooting drill.

**Architecture:** App A and App B share focused bases and render into both regional overlays; Grafana renders only in the primary cluster. MCI/MCS and its BackendConfig/FrontendConfig objects render only for the `us-central1` Fleet configuration cluster, with HTTP, TLS-attachment, and HTTPS-redirect stages. Python contract tests inspect rendered YAML and dashboard JSON; Kind proves workload readiness behavior but does not emulate GKE or MCI.

**Tech Stack:** Kustomize 5.8.1, kubectl/Kubernetes schema 1.35.8, GKE MCI/MCS CRDs, Docker Hub OCI digests, Python 3.13.15/PyYAML/pytest, OPA Conftest 0.68.2, Kubeconform 0.7.0, Kind 0.31.0, Grafana, BigQuery Standard SQL.

**Spec:** `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`

## Global Constraints

- Do not add application source, Dockerfiles, container builds, Helm charts, Gateway API baseline objects, or cloud-side mutations.
- Use App A source tag `docker.io/nginxinc/nginx-unprivileged:1.30.4-alpine3.24`, App B source tag `docker.io/traefik/whoami:v1.12.0`, and Grafana source tag `docker.io/grafana/grafana:12.2.5-ubuntu` with BigQuery plugin `3.4.0`; commit only resolved manifest-list digests in workloads. A newer fixed Grafana patch is selected and documented only if this candidate fails the fixed-Critical scan or plugin-compatibility gate.
- `policy/images.yaml` is the only allowlist and records repository, reviewed source tag, immutable digest, supported platforms, review date, and purpose.
- Render App A and App B in both regions with `replicas: 3`, HPA `minReplicas: 3`, HPA `maxReplicas: 10`, CPU target `70`, PDB `minAvailable: 2`, `maxUnavailable: 0`, and `maxSurge: 1`.
- Run App A as UID/GID 101 on port 8080; run App B as UID/GID 65532 with `--port=8080`; run all app containers non-root with all Linux capabilities dropped, RuntimeDefault seccomp, no privilege escalation, and read-only root filesystems.
- App A uses `/healthz`; App B uses `/health`. Startup, readiness, liveness, and load-balancer health checks must agree with the same port/path contract.
- Requests/limits are App A `250m/256Mi` and `500m/512Mi`; App B `100m/128Mi` and `200m/256Mi`.
- Each app has zone and hostname topology spread with `maxSkew: 1`; zone spread uses `minDomains: 2` and does not block recovery after one unavailable zone.
- Services remain `ClusterIP`; only MCI exposes application traffic. Grafana is `ClusterIP` and accessed by authenticated port-forward.
- MCS objects explicitly select `us-central1/gke-assessment-us-central1` and `us-east1/gke-assessment-us-east1`.
- HTTP uses the Terraform-reserved literal global IP. TLS attachment adds the Terraform-created pre-shared Google-managed certificate after DNS points to that IP; HTTPS redirect is enabled only after the attached certificate becomes active and an HTTPS smoke test succeeds.
- Do not create a Kubernetes `ManagedCertificate`; MCI does not support declarative creation of that resource.
- Exactly three Grafana dashboard exports are committed. `assessment-overview.json` has the four required panels and variables `cluster`, `region`, `namespace`, and `application`.
- Every BigQuery data query has a bounded `timestamp` predicate; schema metadata queries are the documented exception.
- No dashboard or evidence file claims live data, a successful data source, or a screenshot before a future deployment.

---

## File Structure

```text
k8s/
├── base/
│   ├── namespace/{kustomization.yaml,namespaces.yaml}
│   ├── app-a/{kustomization.yaml,configmap.yaml,serviceaccount.yaml,secret-provider-class.yaml,deployment.yaml,service.yaml,hpa.yaml,pdb.yaml,networkpolicy.yaml}
│   ├── app-b/{kustomization.yaml,serviceaccount.yaml,deployment.yaml,service.yaml,hpa.yaml,pdb.yaml,networkpolicy.yaml}
│   ├── pipeline-rbac/
│   │   ├── common/{kustomization.yaml,gateway-impersonate-role.yaml,gateway-impersonate-binding.yaml,assessment-role.yaml,assessment-binding.yaml}
│   │   └── observability/{kustomization.yaml,observability-role.yaml,observability-binding.yaml}
│   └── grafana/
│       ├── {kustomization.yaml,serviceaccount.yaml,secret-provider-class.yaml,deployment.yaml,service.yaml,networkpolicy.yaml}
│       └── files/{provisioning/{grafana.ini,datasources.yaml,dashboard-providers.yaml},dashboards/{assessment-overview.json,multicluster-operations.json,traffic-log-analysis.json}}
├── multicluster/
│   ├── base/{kustomization.yaml,backendconfig-app-a.yaml,backendconfig-app-b.yaml,mcs-app-a.yaml,mcs-app-b.yaml,mci.yaml}
│   ├── tls/{kustomization.yaml,mci-tls-patch.yaml}
│   ├── https-redirect/{kustomization.yaml,frontendconfig.yaml,mci-redirect-patch.yaml}
│   └── pipeline-rbac/{kustomization.yaml,mci-role.yaml,mci-binding.yaml}
├── overlays/
│   ├── us-central1/{kustomization.yaml,region-label-patch.yaml}
│   ├── us-east1/{kustomization.yaml,region-label-patch.yaml}
│   └── config-us-central1/{http/kustomization.yaml,tls/kustomization.yaml,https/kustomization.yaml}
└── kind/
    ├── healthy/{kustomization.yaml,remove-cloud-integrations-patch.yaml,image-pull-policy-patch.yaml}
    └── readiness-failure/{kustomization.yaml,invalid-readiness-patch.yaml}
observability/
└── bigquery/
    ├── README.md
    └── queries/{load-balancer-error-rate.sql,application-logs.sql,node-logs.sql,control-plane-logs.sql,load-balancer-logs.sql,traffic-analysis.sql,schema-discovery.sql}
policy/
├── images.yaml
├── image-exceptions.yaml
└── kubernetes.rego
scripts/lib/
├── manifests.py
├── images.py
├── dashboards.py
└── sql.py
tests/unit/
├── test_image_policy.py
├── test_manifest_policy.py
├── test_mci_policy.py
├── test_dashboard_policy.py
└── test_sql_policy.py
tests/kind/test_readiness_drill.sh
.sqlfluff
```

### Task 1: Immutable image policy and resolver

**Files:**
- Create: `policy/images.yaml`, `policy/image-exceptions.yaml`
- Create: `scripts/lib/images.py`
- Create: `tests/unit/test_image_policy.py`
- Modify: `scripts/validate.py`
- Modify later: three Deployment manifests

**Interfaces:**
- Produces `ImageRecord(name:str, repository:str, source_tag:str, digest:str, platforms:tuple[str,...], purpose:str)`.
- Produces `load_image_policy(path: Path) -> dict[str, ImageRecord]`, `validate_image_reference(reference: str, allowed: dict[str, ImageRecord]) -> list[str]`, and CLI subcommand `validate.py images --resolve --out PATH`.

- [ ] **Step 1: Write the failing unit tests**

```python
import pytest
from scripts.lib.images import validate_image_reference


ALLOWED = {
    "app-a": {
        "repository": "docker.io/nginxinc/nginx-unprivileged",
        "digest": "sha256:" + "a" * 64,
    }
}


def test_canonical_allowed_digest_passes():
    ref = "docker.io/nginxinc/nginx-unprivileged@sha256:" + "a" * 64
    assert validate_image_reference(ref, ALLOWED) == []


@pytest.mark.parametrize("ref", [
    "nginxinc/nginx-unprivileged:latest",
    "docker.io/nginxinc/nginx-unprivileged:1.30.4-alpine3.24",
    "ghcr.io/nginxinc/nginx-unprivileged@sha256:" + "a" * 64,
])
def test_tag_unqualified_or_non_docker_hub_reference_fails(ref):
    assert validate_image_reference(ref, ALLOWED)
```

- [ ] **Step 2: Run and prove the module is absent**

Run: `python3 -m pytest tests/unit/test_image_policy.py -q`

Expected: FAIL importing `scripts.lib.images`.

- [ ] **Step 3: Implement the strict parser**

Use regex `^docker\.io/[a-z0-9._-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$`. The validator rejects a tag, mixed-case digest, digest not equal to the allowlist value, repository not equal to the named record, missing `linux/amd64`, or an exception without `cve`, `image_digest`, `owner`, `rationale`, and ISO `expires` fields.

- [ ] **Step 4: Resolve the reviewed source tags**

After `make tools` installs `crane`, run:

```bash
crane digest docker.io/nginxinc/nginx-unprivileged:1.30.4-alpine3.24
crane digest docker.io/traefik/whoami:v1.12.0
crane digest docker.io/grafana/grafana:12.2.5-ubuntu
```

For each digest, run `crane manifest`, record at least `linux/amd64` and `linux/arm64` when present, then scan the digest with Trivy using `--ignore-unfixed --severity HIGH,CRITICAL --exit-code 1`. A fixed High or Critical finding blocks unless its CVE, exact image digest, owner, rationale, and finite expiry are committed to the reviewed exception file; unfixed findings remain visible in the report and risk discussion. Inspect or run the pinned App A image account-free to require `/bin/sh`, `envsubst`, an HTTPS-capable `wget`, and CA roots because startup and the non-echoing live IAM test depend on them. If Grafana `12.2.5-ubuntu` fails its scan or the BigQuery plugin 3.4.0 compatibility test, select the highest Docker Hub Grafana patch release whose documented version range accepts plugin 3.4.0, repeat resolution/scanning, and record that exact source tag. Never record a moving tag.

- [ ] **Step 5: Create the policy records**

`images.yaml` contains exactly `app-a`, `app-b`, and `grafana` and no digest sentinel. `image-exceptions.yaml` begins as an empty `exceptions: []`. Tests assert each digest is 64 lowercase hexadecimal characters and differs from the synthetic unit-test digest.

- [ ] **Step 6: Run policy and registry checks**

```bash
python3 -m pytest tests/unit/test_image_policy.py -q
python3 scripts/validate.py images --resolve --out artifacts/images
```

Expected: PASS; the artifact records manifest-list media type, platforms, digest, scan timestamp, and Trivy result without credentials.

- [ ] **Step 7: Commit**

```bash
git add policy/images.yaml policy/image-exceptions.yaml scripts/lib/images.py tests/unit/test_image_policy.py
git commit -m "build: lock approved Docker Hub images"
```

### Task 2: App A, App B, and both regional overlays

**Files:**
- Create: `k8s/base/namespace/*`, `k8s/base/app-a/*`, `k8s/base/app-b/*`
- Create: `k8s/base/pipeline-rbac/*`
- Create: `k8s/overlays/us-central1/*`, `k8s/overlays/us-east1/*`
- Create: `scripts/lib/manifests.py`, `tests/unit/test_manifest_policy.py`, `policy/kubernetes.rego`
- Modify: `scripts/validate.py`

**Interfaces:**
- Consumes: `policy/images.yaml`; tokens `${APP_A_GSA_EMAIL}`, `${GCP_PROJECT_ID}`, and `${GCP_PROJECT_NUMBER}`.
- Consumes immutable `scripts.lib.validation.Violation(code:str, path:str, message:str)` from the shared harness.
- Produces `render_overlay(path: Path, substitutions: Mapping[str,str]) -> list[dict]` and `validate_workload_documents(documents: list[dict]) -> list[Violation]`.
- Consumes the shared `runtime_values` pytest fixture from `tests/conftest.py`, populated with non-secret syntactically valid values for all eight renderer tokens.

- [ ] **Step 1: Write the failing workload contract**

```python
from pathlib import Path

import pytest
from scripts.lib.manifests import render_overlay, validate_workload_documents


@pytest.mark.parametrize("region", ["us-central1", "us-east1"])
def test_each_region_has_three_hardened_replicas_per_app(region, runtime_values):
    docs = render_overlay(Path(f"k8s/overlays/{region}"), runtime_values)
    assert validate_workload_documents(docs) == []
    deployments = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Deployment"}
    assert deployments["app-a"]["spec"]["replicas"] == 3
    assert deployments["app-b"]["spec"]["replicas"] == 3
```

Add focused assertions for HPA 3-10/70, PDB 2, probes, matching Service ports, resources, security contexts, update strategy, App A's restricted envsubst/start command, and two topology spread constraints. Require `maxSkew: 1` for both constraints; zone uses `DoNotSchedule` with `minDomains: 2`, while hostname uses `ScheduleAnyway`, so each region spreads across zones when capacity permits and still tolerates a constrained Autopilot placement.

- [ ] **Step 2: Run and prove overlays are absent**

Run: `python3 -m pytest tests/unit/test_manifest_policy.py -q`

Expected: FAIL because neither overlay exists.

- [ ] **Step 3: Implement namespaces and App A**

Create namespaces `assessment` and `observability` with Pod Security Admission labels `enforce/audit/warn: restricted` and version `latest`. App A:

- KSA `assessment/app-a` annotated `iam.gke.io/gcp-service-account: ${APP_A_GSA_EMAIL}` and `iam.gke.io/return-principal-id-as-email: "true"`.
- NGINX ConfigMap supplies a template that sets `pid /tmp/nginx.pid`, client/proxy/FastCGI temp paths under `/tmp`, emits access logs to `/dev/stdout` and error logs to `/dev/stderr`, listens on 8080, serves `/healthz` as plain `ok`, serves `/app-a` with assessment and `$ASSESSMENT_REGION` headers, and never maps `/var/run/secrets` to a public location.
- The container overrides the image entrypoint with `/bin/sh -ceu`; it runs `envsubst '$ASSESSMENT_REGION'` from the read-only template into `/tmp/nginx.conf`, then `exec nginx -c /tmp/nginx.conf -g 'daemon off;'`. This uses the upstream image's existing envsubst binary, avoids entrypoint writes on the read-only root filesystem, substitutes no repository `${...}` token, and makes the regional overlay value visible in responses.
- SecretProviderClass mounts `projects/${GCP_PROJECT_NUMBER}/secrets/app-a-demo/versions/latest` read-only at `/var/run/secrets/assessment`.
- Deployment uses the App A digest, UID/GID 101, pod `fsGroup: 101` with `fsGroupChangePolicy: OnRootMismatch`, read-only root, writable `/tmp`, the approved resources/probes/rollout/spread values, and `automountServiceAccountToken: true` only because Workload Identity/CSI requires it.
- ClusterIP Service exposes named port `http` 8080.

- [ ] **Step 4: Implement App B**

App B uses KSA `assessment/app-b` with `automountServiceAccountToken: false`, the App B digest, arguments `--port=8080` and `--name=schwab-assessment-app-b`, UID/GID 65532, no writable volume, `/health` probes on 8080, the approved resources/rollout/spread values, ClusterIP port 8080, HPA 3-10/70, and PDB 2.

- [ ] **Step 5: Add regional labels without changing replica policy**

Both overlays include namespace, App A, and App B bases. Each patch adds `assessment.schwab/region` to Deployment and Pod-template labels and environment variable `ASSESSMENT_REGION`; neither overlay patches `replicas`, HPA, PDB, images, probes, or security.

- [ ] **Step 6: Add network policies that do not break MCI**

For each app allow ingress to port 8080 from pods in `assessment` and from GFE proxy/health ranges `130.211.0.0/22` and `35.191.0.0/16`. Do not add an egress-deny rule to the workload baseline. Grafana receives a separate policy in Task 4.

- [ ] **Step 7: Add namespace-scoped pipeline RBAC**

Bind user `assessment-deployer@${GCP_PROJECT_ID}.iam.gserviceaccount.com` to explicit Roles, never `cluster-admin`: the `assessment` Role manages and observes only the committed app resource kinds (Deployments/ReplicaSets, HPAs, PDBs, Services, ConfigMaps, ServiceAccounts, NetworkPolicies, SecretProviderClasses, Pods, events, and EndpointSlices), with explicit subresource access for logs and `get` on `pods/exec`, `pods/attach`, and `pods/portforward`; the `observability` Role has the equivalent minimum Grafana kinds and the same explicit streaming `get` permissions required for authenticated dashboard port-forward through Connect Gateway. Add the Connect Gateway impersonation pair required on every cluster: a ClusterRole permits only `impersonate` on core `users` with `resourceNames` containing exactly the deployer email, and its ClusterRoleBinding binds only `gke-connect/connect-agent-sa`. Include the assessment binding and gateway pair in both regional overlays and the observability binding only in `us-central1`. Tests reject wildcard resources/verbs, unexpected subjects, or any `cluster-admin` reference.

The first RBAC bootstrap uses an ephemeral kubeconfig through each cluster's IAM-aware DNS endpoint immediately after platform creation; once the committed impersonation policy exists, all normal delivery, verification, and teardown traffic uses Connect Gateway. The broad GCP `container.admin` grant is an intentional consequence of the one-identity assessment choice and can still authorize wider Kubernetes operations through GKE's IAM fallback; the ADR explains that production separates infrastructure bootstrap from a namespace-only workload identity so the RBAC boundary becomes enforceable.

- [ ] **Step 8: Render and validate**

```bash
kustomize build k8s/overlays/us-central1 > artifacts/rendered/us-central1.yaml
kustomize build k8s/overlays/us-east1 > artifacts/rendered/us-east1.yaml
python3 -m pytest tests/unit/test_manifest_policy.py -q
kubeconform -strict -summary -kubernetes-version 1.35.8 -ignore-missing-schemas artifacts/rendered/us-central1.yaml artifacts/rendered/us-east1.yaml
conftest test --policy policy/kubernetes.rego artifacts/rendered/us-central1.yaml artifacts/rendered/us-east1.yaml
```

Expected: PASS. Kubeconform may ignore only GKE custom resources; ordinary Kubernetes schema failures remain fatal.

- [ ] **Step 9: Commit**

```bash
git add k8s/base k8s/overlays policy/kubernetes.rego scripts/lib/manifests.py scripts/validate.py tests/unit/test_manifest_policy.py
git commit -m "feat: add regional three-replica workloads"
```

### Task 3: MCI/MCS HTTP baseline and staged HTTPS

**Files:**
- Create: `k8s/multicluster/base/*`, `k8s/multicluster/{tls,https-redirect,pipeline-rbac}/*`
- Create: `k8s/overlays/config-us-central1/{http,tls,https}/kustomization.yaml`
- Create: `tests/unit/test_mci_policy.py`
- Extend: `scripts/lib/manifests.py`

**Interfaces:**
- Consumes tokens `${GCP_PROJECT_ID}`, `${GLOBAL_IP_ADDRESS}`, `${CLOUD_ARMOR_POLICY}`, `${TLS_CERTIFICATE_NAME}` and fixed membership links guaranteed by the platform Terraform tests.
- Produces `validate_mci_documents(http_docs:list[dict], tls_docs:list[dict], https_docs:list[dict]) -> list[Violation]`.

- [ ] **Step 1: Write the failing traffic contract**

```python
def test_http_tls_and_redirect_are_safe_stages(runtime_values):
    http = render_overlay(Path("k8s/overlays/config-us-central1/http"), runtime_values)
    tls = render_overlay(Path("k8s/overlays/config-us-central1/tls"), runtime_values)
    https = render_overlay(Path("k8s/overlays/config-us-central1/https"), runtime_values)
    assert validate_mci_documents(http, tls, https) == []
    http_mci = one(http, kind="MultiClusterIngress")
    tls_mci = one(tls, kind="MultiClusterIngress")
    https_mci = one(https, kind="MultiClusterIngress")
    assert "networking.gke.io/pre-shared-certs" not in http_mci["metadata"]["annotations"]
    assert "networking.gke.io/frontend-config" not in tls_mci["metadata"]["annotations"]
    assert tls_mci["metadata"]["annotations"]["networking.gke.io/pre-shared-certs"] == runtime_values["TLS_CERTIFICATE_NAME"]
    assert https_mci["metadata"]["annotations"]["networking.gke.io/pre-shared-certs"] == runtime_values["TLS_CERTIFICATE_NAME"]
```

Add assertions for exact paths, default backend, literal IP annotation, explicit cluster links, BackendConfig mapping, health ports/paths, logging sample rate 1.0, Cloud Armor token, and no baseline Gateway kinds.

- [ ] **Step 2: Run and prove traffic overlays are absent**

Run: `python3 -m pytest tests/unit/test_mci_policy.py -q`

Expected: FAIL due to missing overlays.

- [ ] **Step 3: Implement BackendConfigs and explicit MCS resources**

Create `cloud.google.com/v1` BackendConfigs `app-a-backend` and `app-b-backend` with HTTP health checks on port 8080, paths `/healthz` and `/health`, interval/timeout 5 seconds, healthy/unhealthy threshold 2, connection draining 30 seconds, request logging enabled at 1.0, and `securityPolicy.name: ${CLOUD_ARMOR_POLICY}`.

Create `networking.gke.io/v1` MCS objects `app-a-mcs` and `app-b-mcs`. Each template selects its stable app label, uses named TCP port `http` 8080, and attaches `app-a-backend` or `app-b-backend` respectively with `cloud.google.com/backend-config: '{"ports":{"8080":"app-a-backend"}}'` or `'{"ports":{"8080":"app-b-backend"}}'`. Both list exactly:

```yaml
clusters:
  - link: us-central1/gke-assessment-us-central1
  - link: us-east1/gke-assessment-us-east1
```

- [ ] **Step 4: Implement the HTTP-first MCI**

Create one MCI `assessment-ingress` in namespace `assessment`, annotate `networking.gke.io/static-ip: ${GLOBAL_IP_ADDRESS}`, use App A as required default backend, and route `/app-a` to `app-a-mcs:8080` and `/app-b` to `app-b-mcs:8080`. The HTTP config overlay contains no TLS, certificate, or redirect object.

- [ ] **Step 5: Implement TLS attachment without redirect**

The TLS component adds only `networking.gke.io/pre-shared-certs: ${TLS_CERTIFICATE_NAME}` to the MCI. It retains the literal static IP and contains no FrontendConfig or redirect. This attachment lets Google validate the DNS/IP relationship and activate the Compute-managed certificate while HTTP remains usable.

- [ ] **Step 6: Implement redirect after certificate activation**

The HTTPS-redirect component builds on the TLS component and adds:

```yaml
apiVersion: networking.gke.io/v1beta1
kind: FrontendConfig
metadata:
  name: assessment-https
  namespace: assessment
spec:
  sslPolicy: schwab-assessment-tls
  redirectToHttps:
    enabled: true
```

Patch MCI annotations with `networking.gke.io/frontend-config: assessment-https` while retaining `networking.gke.io/pre-shared-certs: ${TLS_CERTIFICATE_NAME}` and the literal static IP. The deployment script applies HTTP, proves DNS resolves to the reserved IP, applies TLS attachment, waits for the Compute certificate to become `ACTIVE`, proves direct HTTPS, and only then applies this redirect stage.

- [ ] **Step 7: Add configuration-cluster MCI RBAC**

Bind `assessment-deployer@${GCP_PROJECT_ID}.iam.gserviceaccount.com` in namespace `assessment` to a Role that manages and observes only `MultiClusterIngress`, `MultiClusterService`, `BackendConfig`, and `FrontendConfig` resources. All three configuration overlays include this Role/RoleBinding, and contract tests reject wildcard resources, wildcard verbs, or any `cluster-admin` reference.

- [ ] **Step 8: Render and validate all three stages**

```bash
kustomize build k8s/overlays/config-us-central1/http > artifacts/rendered/mci-http.yaml
kustomize build k8s/overlays/config-us-central1/tls > artifacts/rendered/mci-tls.yaml
kustomize build k8s/overlays/config-us-central1/https > artifacts/rendered/mci-https.yaml
python3 -m pytest tests/unit/test_mci_policy.py -q
kubeconform -strict -summary -ignore-missing-schemas artifacts/rendered/mci-http.yaml artifacts/rendered/mci-tls.yaml artifacts/rendered/mci-https.yaml
conftest test --policy policy/kubernetes.rego artifacts/rendered/mci-http.yaml artifacts/rendered/mci-tls.yaml artifacts/rendered/mci-https.yaml
```

Expected: PASS; Python/Rego provide strict field checks for GKE CRDs unavailable in generic Kubernetes schemas.

- [ ] **Step 9: Commit**

```bash
git add k8s/multicluster k8s/overlays/config-us-central1 scripts/lib/manifests.py tests/unit/test_mci_policy.py
git commit -m "feat: add staged multi-cluster ingress"
```

### Task 4: Internal Grafana and three dashboard exports

**Files:**
- Create: `k8s/base/grafana/*`
- Create: `k8s/base/grafana/files/provisioning/*`
- Create: `k8s/base/grafana/files/dashboards/*`
- Extend: `k8s/overlays/us-central1/kustomization.yaml`
- Create: `scripts/lib/dashboards.py`, `tests/unit/test_dashboard_policy.py`
- Modify: `scripts/validate.py`

**Interfaces:**
- Consumes tokens `${GRAFANA_GSA_EMAIL}`, `${GCP_PROJECT_ID}`, `${BIGQUERY_DATASET}` and Grafana image record.
- Produces `load_dashboards(path:Path) -> list[Dashboard]`, `validate_dashboards(dashboards:list[Dashboard]) -> list[Violation]`, and three stable UIDs `assessment-overview`, `multicluster-operations`, `traffic-log-analysis`.

- [ ] **Step 1: Write the failing dashboard contract**

```python
from pathlib import Path

def test_exact_dashboard_inventory_and_overview_panels():
    dashboards = load_dashboards(Path("k8s/base/grafana/files/dashboards"))
    assert {d.uid for d in dashboards} == {
        "assessment-overview",
        "multicluster-operations",
        "traffic-log-analysis",
    }
    overview = next(d for d in dashboards if d.uid == "assessment-overview")
    assert {p.title for p in overview.panels} == {
        "Application error rate",
        "Pod restarts",
        "Request latency p50/p95/p99",
        "CPU and memory utilization",
    }
    assert {v.name for v in overview.variables} >= {"cluster", "region", "namespace", "application"}
```

Add token tests for BigQuery `SAFE_DIVIDE`/5xx/time filter, restart metric, backend-latency metric and three percentile aligners, CPU/memory metrics, unique panel IDs/titles, valid provisioned datasource UIDs, metadata auth, accessible-dataset restriction, and the exact 1 GiB per-query billing cap.

- [ ] **Step 2: Run and prove dashboards are absent**

Run: `python3 -m pytest tests/unit/test_dashboard_policy.py -q`

Expected: FAIL with an empty dashboard inventory.

- [ ] **Step 3: Provision keyless data sources**

`datasources.yaml` defines stable UIDs `gcp-monitoring` (built-in type `stackdriver`) and `gcp-bigquery` (type `grafana-bigquery-datasource`), proxy access, metadata-server authentication `gce`, default project `${GCP_PROJECT_ID}`, BigQuery processing location `US`, `MaxBytesBilled: 1073741824`, and `restrictToAccessibleDatasets: true`; dataset-level IAM makes `${BIGQUERY_DATASET}` the only routed-log dataset available. No `privateKey`, credential file, or service-account JSON field exists. `dashboard-providers.yaml` loads read-only dashboards from `/var/lib/grafana/dashboards`.

- [ ] **Step 4: Implement the overview export**

Use schemaVersion supported by the pinned Grafana image and exactly four panels:

1. BigQuery application error rate: `100 * SAFE_DIVIDE(COUNTIF(httpRequest.status BETWEEN 500 AND 599), COUNT(*))`, grouped by minute/application path with `$__timeFilter(timestamp)`.
2. Cloud Monitoring `kubernetes.io/container/restart_count`, grouped by namespace/workload/pod.
3. Cloud Monitoring `loadbalancing.googleapis.com/https/backend_latencies` with percentile 50, 95, and 99 targets.
4. Cloud Monitoring `kubernetes.io/container/cpu/core_usage_time` and `kubernetes.io/container/memory/used_bytes` targets.

Dashboard constants receive `${GCP_PROJECT_ID}` and `${BIGQUERY_DATASET}` through the allowed renderer; workload dimensions are user-visible variables.

- [ ] **Step 5: Implement supporting exports**

`multicluster-operations.json` includes ready/desired replicas, restart change, HPA current/desired, regional/zone pod placement, and regional health panels. `traffic-log-analysis.json` includes request rate, status classes, backend latency, Cloud Armor outcome, and bounded log-explorer table panels. Every BigQuery target contains `$__timeFilter(timestamp)`.

- [ ] **Step 6: Deploy Grafana internally**

Use KSA `observability/grafana` annotated with `iam.gke.io/gcp-service-account: ${GRAFANA_GSA_EMAIL}` and `iam.gke.io/return-principal-id-as-email: "true"`, with `automountServiceAccountToken: true` explicitly retained for GKE metadata-server and CSI identity, plus SecretProviderClass for `grafana-admin`. Deployment:

- one replica, Recreate strategy, UID/GID and `fsGroup` 472 with `fsGroupChangePolicy: OnRootMismatch`, RuntimeDefault, capabilities dropped, no privilege escalation;
- pinned Grafana digest and BigQuery plugin version 3.4.0;
- `GF_PLUGINS_PREINSTALL_SYNC=grafana-bigquery-datasource@3.4.0` and `GF_PATHS_PLUGINS=/var/lib/grafana/plugins`; synchronous preinstall writes to the plugin emptyDir and blocks Grafana startup, so a download/install failure makes the container fail and readiness stay false rather than starting with a broken datasource;
- `GF_SECURITY_ADMIN_PASSWORD__FILE=/var/run/secrets/grafana/admin-password` and fixed admin user `admin`;
- config/provisioning/dashboard ConfigMaps mounted read-only; writable emptyDirs only for data/plugins/log/tmp paths;
- readiness/liveness on `/api/health:3000`;
- ClusterIP Service only, no Ingress/MCI;
- egress policy permits cluster DNS, TCP 443, and only the documented GKE metadata paths (`169.254.169.254/32` on TCP 80/8080 for Dataplane V2 and `169.254.169.252/32` on TCP 987/988 for the alternate metadata path); ingress permits TCP 3000 from the cluster so authenticated `kubectl port-forward` works.

Include Grafana only in `us-central1` overlay. App replica assertions ignore Grafana by name but still require the two apps in both regions.

The Grafana base `kustomization.yaml` uses `configMapGenerator` entries whose source files live below that same base, preserving Kustomize's default load restrictions. It generates the Grafana config/provisioning ConfigMap and one dashboard ConfigMap containing all three JSON exports; the Deployment mounts those generated names. Tests render the primary overlay and assert the mounted ConfigMaps contain `grafana.ini`, both datasource/provider YAML files, all three dashboard JSON files, exact plugin environment/version, and matching datasource type `grafana-bigquery-datasource`.

The assessment intentionally downloads the fixed catalog plugin version at pod start because no custom image is built. Document this availability/supply-chain dependency and the production recommendation to verify the publisher signature/checksum, mirror the plugin, and bake it into an owned digest-pinned Grafana image.

- [ ] **Step 7: Validate dashboards and manifests**

```bash
python3 -m pytest tests/unit/test_dashboard_policy.py tests/unit/test_manifest_policy.py -q
kustomize build k8s/overlays/us-central1 > artifacts/rendered/us-central1.yaml
python3 scripts/validate.py dashboards --out artifacts/dashboards
```

Expected: PASS and a panel inventory listing all three exports and required query tokens. It does not report live datasource success.

- [ ] **Step 8: Commit**

```bash
git add k8s/base/grafana k8s/overlays/us-central1 scripts/lib/dashboards.py scripts/validate.py tests/unit/test_dashboard_policy.py
git commit -m "feat: provision Grafana assessment dashboards"
```

### Task 5: BigQuery analysis query pack

**Files:**
- Create: `observability/bigquery/README.md`, `observability/bigquery/queries/*.sql`
- Create: `.sqlfluff`
- Create: `scripts/lib/sql.py`, `tests/unit/test_sql_policy.py`
- Modify: `scripts/validate.py`

**Interfaces:**
- Consumes substitution values `GCP_PROJECT_ID`, `BIGQUERY_DATASET`, `start_time`, and `end_time`.
- Produces `validate_sql_file(path:Path) -> list[Violation]` and seven executable Standard SQL samples.

- [ ] **Step 1: Write the failing SQL contract**

```python
from pathlib import Path

REQUIRED = {
    "load-balancer-error-rate.sql": "httpRequest.status",
    "application-logs.sql": "k8s_container",
    "node-logs.sql": "k8s_node",
    "control-plane-logs.sql": "k8s_control_plane_component",
    "load-balancer-logs.sql": "http_load_balancer",
    "traffic-analysis.sql": "httpRequest.latency",
    "schema-discovery.sql": "INFORMATION_SCHEMA.COLUMNS",
}


def test_required_queries_exist_and_data_queries_are_bounded():
    for filename, token in REQUIRED.items():
        sql = (Path("observability/bigquery/queries") / filename).read_text()
        assert token in sql
        if filename != "schema-discovery.sql":
            assert "timestamp BETWEEN @start_time AND @end_time" in sql
```

- [ ] **Step 2: Run and prove query files are absent**

Run: `python3 -m pytest tests/unit/test_sql_policy.py -q`

Expected: FAIL reading the first missing query.

- [ ] **Step 3: Implement the seven queries**

Use fully qualified backtick identifiers with `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}`. The error-rate query reads partitioned `requests`, derives `/app-a` versus `/app-b` from `httpRequest.requestUrl`, groups by minute/path, and uses `SAFE_DIVIDE`. Application samples read `stdout`; node samples read `kubelet`; control-plane samples use bounded `UNION ALL` branches for `kube_apiserver`, `kube_scheduler`, and `kube_controller_manager`; LB samples read `requests`; traffic analysis safely parses the Logging duration string and groups status/latency. Schema discovery reads dataset `INFORMATION_SCHEMA.COLUMNS` and states why no timestamp predicate applies to metadata.

- [ ] **Step 4: Document routed-log schema uncertainty**

`README.md` explains table-per-log-name behavior, partitioning on exported `timestamp`, first-record schema creation, likely tables versus discovered tables, stable native `httpRequest` fields, normalized payload fields, parameter use, cost controls, and the future verification command that first lists actual tables before running bounded samples.

- [ ] **Step 5: Lint and test**

Configure `.sqlfluff` with dialect `bigquery`, templater `placeholder`, placeholder `param_style = dollar`, and harmless identifier samples `GCP_PROJECT_ID = assessment-project` and `BIGQUERY_DATASET = assessment_logs`. This makes `${GCP_PROJECT_ID}` and `${BIGQUERY_DATASET}` parse without altering the committed executable templates; BigQuery `@start_time` and `@end_time` parameters remain native query parameters.

```bash
python3 -m pytest tests/unit/test_sql_policy.py -q
sqlfluff lint observability/bigquery/queries
python3 scripts/validate.py sql --out artifacts/sql
```

Expected: PASS; the report classifies syntax/contract validation as account-free and query results as deployment evidence pending.

- [ ] **Step 6: Commit**

```bash
git add .sqlfluff observability/bigquery scripts/lib/sql.py scripts/validate.py tests/unit/test_sql_policy.py
git commit -m "feat: add bounded BigQuery log analysis"
```

### Task 6: Kind readiness diagnosis and recovery

**Files:**
- Create: `k8s/kind/healthy/*`, `k8s/kind/readiness-failure/*`
- Create: `tests/kind/test_readiness_drill.sh`
- Extend: `tests/unit/test_manifest_policy.py`

**Interfaces:**
- Consumes: app bases and locked public images.
- Produces ignored `artifacts/kind/{healthy,failed,recovered}/` evidence and a deterministic local diagnosis.

- [ ] **Step 1: Write the failing drill contract**

The shell test creates a Kind cluster `assessment-ci`, renders the healthy overlay, applies it, and requires:

```bash
kubectl -n assessment rollout status deployment/app-a --timeout=180s
kubectl -n assessment rollout status deployment/app-b --timeout=180s
test "$(kubectl -n assessment get deployment app-a -o jsonpath='{.status.readyReplicas}')" = "3"
test "$(kubectl -n assessment get deployment app-b -o jsonpath='{.status.readyReplicas}')" = "3"
```

Run: `bash tests/kind/test_readiness_drill.sh`

Expected: FAIL because the Kind overlays do not exist; cleanup trap still removes only cluster `assessment-ci`.

- [ ] **Step 2: Implement cloud-free Kind overlays**

The healthy overlay includes namespace and both apps, sets `imagePullPolicy: IfNotPresent`, removes App A's CSI volume/mount/SecretProviderClass and Workload Identity annotations, and preserves replica/HPA/PDB/probe/security/resource contracts. It explicitly removes the production topology-spread constraints because the one-node Kind cluster has neither two eligible zones nor three hostnames; the regional overlays remain the statically tested source of truth for those constraints. Without this test-only patch, `minDomains: 2` plus zone `DoNotSchedule` would prevent three local replicas. The overlay does not include Grafana, MCI, or GKE CRDs.

- [ ] **Step 3: Implement the controlled failure**

The failure overlay changes only App A readiness path to `/intentionally-not-ready`. Before applying it, the drill deliberately deletes only the healthy App A Deployment and waits until its Pods and ready EndpointSlice entries are gone; it retains App B, the Service, and all other resources. This reset is required because the production rollout contract has `maxUnavailable: 0` and would correctly retain old healthy Pods while a broken revision stalls, masking the zero-endpoint diagnostic. The drill then applies the broken App A Deployment, requires rollout wait to fail within 30 seconds, captures deployment/pods/events/logs/EndpointSlices, and asserts three App A Pods exist but no App A EndpointSlice endpoint has `conditions.ready == true`.

- [ ] **Step 4: Implement recovery proof**

Reapply the healthy overlay, wait for rollout, assert three Ready App A replicas and ready endpoints, and capture recovered output. Every artifact begins with UTC timestamp, commit SHA, Kind/Kubernetes version, and label `local-controlled-readiness-drill`.

- [ ] **Step 5: Run and commit**

```bash
python3 -m pytest tests/unit/test_manifest_policy.py -q
bash tests/kind/test_readiness_drill.sh
```

Expected: PASS on a Docker-capable host. A host without Docker fails with a clear prerequisite message; CI must run the drill rather than skip it.

```bash
git add k8s/kind tests/kind tests/unit/test_manifest_policy.py
git commit -m "test: add reproducible readiness failure drill"
```

## Live-Only Boundary

Static validation proves rendering, immutability, policy fields, query text, dashboard exports, and local readiness diagnosis. It cannot prove Docker Hub pull behavior from GKE, Autopilot scheduling, HPA reaction, PDB behavior during GKE maintenance, Workload Identity/Secret Manager access, MCI reconciliation, NEGs/backend health, Cloud Armor attachment, regional routing/failover, certificate activation, log ingestion/table names, Cloud Monitoring time series, Grafana plugin installation, datasource authentication, rendered panel values, or screenshots. Those remain `deployment-evidence-pending` until the future protected workflow records them.

# GKE Assessment Workloads and Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Produce deploy-ready Kustomize workloads for two GKE regions, MCI/MCS routing, internal Grafana with three dashboard exports, and bounded BigQuery log-analysis templates, without cloud deployment.

**Architecture:** App A and App B share Kustomize bases rendered into two equal-capacity regional overlays. MCI/MCS renders only in the us-central1 Fleet configuration cluster through HTTP, TLS-attachment, and HTTPS-redirect stages. Grafana is a single recoverable us-central1 workload; dashboard JSON and SQL are repository artifacts until a future authenticated workflow verifies live integrations.

**Tech Stack:** Kustomize 5.8.1, Kubeconform 0.7.0, jq, GKE MCI/MCS CRDs, Docker Hub digest references, Grafana 12.2.5 with BigQuery datasource plugin 3.4.0, BigQuery Standard SQL.

**Spec:** docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md

## Global Constraints

- Do not deploy, apply to, or mutate cloud resources. Only local rendering, supported-schema validation, and dashboard JSON parsing run during implementation.
- Do not add application source, Dockerfiles, container builds, Helm charts, Gateway API baseline objects, a service mesh, custom validators, custom validation helpers, or a language runtime.
- Use Docker Hub App A source docker.io/nginxinc/nginx-unprivileged:1.30.4-alpine3.24 and App B source docker.io/traefik/whoami:v1.12.0. Resolve each to a canonical docker.io/...@sha256:... digest in its Deployment; never use a moving tag in a workload manifest.
- Use docker.io/grafana/grafana:12.2.5-ubuntu resolved to an immutable digest and plugin grafana-bigquery-datasource@3.4.0. Select and document a compatible fixed patch only if that image cannot run the pinned plugin.
- In each production overlay, App A and App B each set replicas: 3, HPA minReplicas: 3, HPA maxReplicas: 10, CPU target 70, PDB minAvailable: 2, Deployment maxUnavailable: 0, and maxSurge: 1.
- App A runs as UID/GID 101 on port 8080 and serves /healthz. App B runs as UID/GID 65532 with --port=8080 and serves /health. Startup, readiness, liveness, Service, and BackendConfig health checks agree.
- Both apps are non-root with allowPrivilegeEscalation: false, dropped capabilities, RuntimeDefault seccomp, and read-only root filesystems. App A receives writable /tmp; App B receives no writable application filesystem.
- App A requests/limits are 250m/256Mi and 500m/512Mi; App B requests/limits are 100m/128Mi and 200m/256Mi. Both use zone and hostname topology spread with maxSkew: 1; zone uses minDomains: 2 and tolerates a zone loss.
- Services and Grafana are ClusterIP; only MCI exposes application routes. Use Workload Identity KSAs and Secret Manager CSI mounts for App A and Grafana. No secret, key, or credential file is committed.
- Kustomize owns the narrow pipeline RBAC needed by the future delivery workflow: namespaced workload roles, configuration-cluster MCI/MCS access, and the exact Connect Gateway user-impersonation binding. Never bind `cluster-admin` or use wildcard verbs/resources.
- MCS explicitly selects us-central1/gke-assessment-us-central1 and us-east1/gke-assessment-us-east1. Do not create a Kubernetes ManagedCertificate.
- HTTP uses Terraform's reserved global IP. TLS attaches Terraform's pre-shared Google-managed certificate only after DNS points to that IP. HTTPS redirect is a separate overlay after certificate activation and direct HTTPS success in a future deployment.
- Commit exactly three Grafana dashboard exports. assessment-overview.json has exactly four panels: application error rate, pod restarts, request latency p50/p95/p99, and CPU and memory utilization; it defines cluster, region, namespace, and application variables.
- Every BigQuery data query contains a bounded timestamp predicate. The documented INFORMATION_SCHEMA metadata query is the sole exception. Never claim live data, datasource success, screenshots, or deployment evidence before deployment.
- `tools/images.env` is a sourceable inventory containing exactly `APP_A_IMAGE`, `APP_B_IMAGE`, and `GRAFANA_IMAGE`; each value is the corresponding canonical `docker.io/...@sha256:<64 lowercase hex>` reference used by its Deployment.

---

## File Structure

~~~
k8s/
├── access/
│   ├── common/{kustomization.yaml,assessment-role.yaml,assessment-rolebinding.yaml,gateway-impersonation.yaml}
│   ├── us-central1/{kustomization.yaml,observability-role.yaml,observability-rolebinding.yaml}
│   ├── us-east1/kustomization.yaml
│   └── config-us-central1/{kustomization.yaml,multicluster-role.yaml,multicluster-rolebinding.yaml}
├── base/
│   ├── namespace/{kustomization.yaml,namespaces.yaml}
│   ├── app-a/{kustomization.yaml,configmap.yaml,serviceaccount.yaml,secret-provider-class.yaml,deployment.yaml,service.yaml,hpa.yaml,pdb.yaml,networkpolicy.yaml}
│   ├── app-b/{kustomization.yaml,serviceaccount.yaml,deployment.yaml,service.yaml,hpa.yaml,pdb.yaml,networkpolicy.yaml}
│   └── grafana/{kustomization.yaml,serviceaccount.yaml,secret-provider-class.yaml,deployment.yaml,service.yaml,networkpolicy.yaml,files/provisioning/{grafana.ini,datasources.yaml,dashboard-providers.yaml},files/dashboards/{assessment-overview.json,multicluster-operations.json,traffic-log-analysis.json}}
├── multicluster/
│   ├── base/{kustomization.yaml,backendconfig-app-a.yaml,backendconfig-app-b.yaml,mcs-app-a.yaml,mcs-app-b.yaml,mci.yaml}
│   ├── tls/{kustomization.yaml,mci-tls-patch.yaml}
│   └── https-redirect/{kustomization.yaml,frontendconfig.yaml,mci-redirect-patch.yaml}
└── overlays/
    ├── us-central1/{kustomization.yaml,region-label-patch.yaml}
    ├── us-east1/{kustomization.yaml,region-label-patch.yaml}
    └── config-us-central1/{http/kustomization.yaml,tls/kustomization.yaml,https/kustomization.yaml}
observability/bigquery/
├── README.md
└── queries/{load-balancer-error-rate.sql,application-logs.sql,node-logs.sql,control-plane-logs.sql,load-balancer-logs.sql,traffic-analysis.sql,schema-discovery.sql}
~~~

### Task 1: Create delivery access and shared application workload bases

**Files:**

- Create: k8s/access/common/{kustomization.yaml,assessment-role.yaml,assessment-rolebinding.yaml,gateway-impersonation.yaml}
- Create: k8s/access/us-central1/{kustomization.yaml,observability-role.yaml,observability-rolebinding.yaml}
- Create: k8s/access/us-east1/kustomization.yaml
- Create: k8s/access/config-us-central1/{kustomization.yaml,multicluster-role.yaml,multicluster-rolebinding.yaml}
- Create: k8s/base/namespace/kustomization.yaml
- Create: k8s/base/namespace/namespaces.yaml
- Create: k8s/base/app-a/kustomization.yaml
- Create: k8s/base/app-a/configmap.yaml
- Create: k8s/base/app-a/serviceaccount.yaml
- Create: k8s/base/app-a/secret-provider-class.yaml
- Create: k8s/base/app-a/deployment.yaml
- Create: k8s/base/app-a/service.yaml
- Create: k8s/base/app-a/hpa.yaml
- Create: k8s/base/app-a/pdb.yaml
- Create: k8s/base/app-a/networkpolicy.yaml
- Create: k8s/base/app-b/kustomization.yaml
- Create: k8s/base/app-b/serviceaccount.yaml
- Create: k8s/base/app-b/deployment.yaml
- Create: k8s/base/app-b/service.yaml
- Create: k8s/base/app-b/hpa.yaml
- Create: k8s/base/app-b/pdb.yaml
- Create: k8s/base/app-b/networkpolicy.yaml
- Create: tools/images.env

**Interfaces:**

- Consumes: Terraform output values ASSESSMENT_DEPLOYER_EMAIL, APP_A_GSA_EMAIL, and GCP_PROJECT_NUMBER, plus approved Docker Hub image digests.
- Produces: narrow delivery-access overlays plus labelled App A/App B Deployments, Services, HPAs, PDBs, NetworkPolicies, and an App A SecretProviderClass in namespace assessment.
- Consumed by: k8s/overlays/us-central1/kustomization.yaml, k8s/overlays/us-east1/kustomization.yaml, k8s/multicluster/base/mcs-app-a.yaml, and k8s/multicluster/base/mcs-app-b.yaml.

- [ ] **Step 1: Resolve App A and App B**

Resolve the reviewed Docker Hub tags to manifest-list digests with `crane`, place each exact digest in its Deployment, and record tag-to-digest provenance in `tools/images.env`.

~~~bash
app_a_digest="$(crane digest docker.io/nginxinc/nginx-unprivileged:1.30.4-alpine3.24)"
app_b_digest="$(crane digest docker.io/traefik/whoami:v1.12.0)"
~~~

Create `tools/images.env` with `APP_A_IMAGE` and `APP_B_IMAGE` set to those exact canonical digest references; Task 4 adds `GRAFANA_IMAGE`. The file contains assignments only, with no shell commands or moving tags. Use the same values verbatim in the Deployments.

- [ ] **Step 2: Add narrowly scoped delivery access**

The common access overlay binds user `ASSESSMENT_DEPLOYER_EMAIL` in namespace `assessment` to a Role limited to Deployments/ReplicaSets, HPAs, PDBs, Services, ConfigMaps, ServiceAccounts, NetworkPolicies, SecretProviderClasses, Pods, events, and EndpointSlices. Add `get` for logs and `get` on `pods/exec`, `pods/attach`, and `pods/portforward`; use no wildcard. Its ClusterRole allows only `impersonate` on core `users` with `resourceNames: [ASSESSMENT_DEPLOYER_EMAIL]`, and its ClusterRoleBinding binds only `gke-connect/connect-agent-sa`.

The central access overlay adds an `observability` Role/RoleBinding with the same minimum Grafana management/streaming needs; the east overlay contains common access only. The configuration-cluster access overlay adds an `assessment` Role/RoleBinding limited to `MultiClusterIngress`, `MultiClusterService`, `BackendConfig`, and `FrontendConfig`. These access overlays are rendered and applied through each IAM-aware DNS endpoint before the delivery script switches to Connect Gateway.

- [ ] **Step 3: Implement App A**

Create restricted assessment and observability Namespaces. App A has a KSA annotated with APP_A_GSA_EMAIL, a SecretProviderClass mounting the App A Secret Manager version identified by GCP_PROJECT_NUMBER at /var/run/secrets/assessment, and a ConfigMap NGINX template. Its Deployment uses the NGINX digest, replicas: 3, UID/GID and fsGroup 101, read-only root, emptyDir /tmp, and /bin/sh -ceu to render /tmp/nginx.conf before starting NGINX. The configuration listens on 8080, logs to stdout/stderr, returns ok at /healthz, serves /app-a, and never exposes the CSI mount. Configure startup, readiness, and liveness at 8080/healthz, required resources, rollout values, and zone/hostname topology spread.

- [ ] **Step 4: Implement App B and availability objects**

App B uses a KSA with automountServiceAccountToken: false, the Traefik digest, replicas: 3, --port=8080, UID/GID 65532, read-only root, no writable application volume, required resources, rollout values, topology spread, and all probes at 8080/health.

For both apps create named http ClusterIP Services on 8080, autoscaling/v2 HPAs with minReplicas: 3, maxReplicas: 10, CPU target 70, and PDBs with minAvailable: 2. NetworkPolicies allow TCP 8080 from assessment and GFE proxy/health ranges 130.211.0.0/22 and 35.191.0.0/16; do not add default egress denial.

- [ ] **Step 5: Build and validate delivery-access overlays**

~~~bash
kustomize build k8s/access/us-central1 | kubeconform -strict -summary -ignore-missing-schemas -
kustomize build k8s/access/us-east1 | kubeconform -strict -summary -ignore-missing-schemas -
kustomize build k8s/access/config-us-central1 | kubeconform -strict -summary -ignore-missing-schemas -
~~~

Expected: supported schemas conform; GKE-specific kinds are skipped only when their schemas are not locally available.

- [ ] **Step 6: Commit access and application bases**

~~~bash
git add k8s/access k8s/base/namespace k8s/base/app-a k8s/base/app-b tools/images.env
git commit -m "feat: add hardened application workload bases"
~~~

### Task 2: Render two regional workload overlays

**Files:**

- Create: k8s/overlays/us-central1/kustomization.yaml
- Create: k8s/overlays/us-central1/region-label-patch.yaml
- Create: k8s/overlays/us-east1/kustomization.yaml
- Create: k8s/overlays/us-east1/region-label-patch.yaml
- Modify: k8s/base/app-a/deployment.yaml

**Interfaces:**

- Consumes: Task 1 resources and ASSESSMENT_REGION values fixed by overlay patches.
- Produces: equal-capacity application workload sets in us-central1 and us-east1.
- Consumed by: the future delivery workflow and the explicit MCS membership selection.

- [ ] **Step 1: Create regional patches**

Both overlays include namespace, App A, and App B bases. The central patch sets Deployment and Pod-template label assessment.schwab/region: us-central1 and App A ASSESSMENT_REGION=us-central1; the eastern patch sets equivalent us-east1 values. Neither overlay changes images, replicas, HPAs, PDBs, probes, resources, rollout strategy, or security context.

- [ ] **Step 2: Build and validate the regional production overlays**

~~~bash
kustomize build k8s/overlays/us-central1 | kubeconform -strict -summary -kubernetes-version 1.35.8 -ignore-missing-schemas -
kustomize build k8s/overlays/us-east1 | kubeconform -strict -summary -kubernetes-version 1.35.8 -ignore-missing-schemas -
~~~

Expected: both production overlays render, and supported Kubernetes schemas conform.

- [ ] **Step 3: Commit regional overlays**

~~~bash
git add k8s/overlays/us-central1 k8s/overlays/us-east1
git commit -m "feat: add symmetric regional workload overlays"
~~~

### Task 3: Add MCI/MCS routing with safe TLS stages

**Files:**

- Create: k8s/multicluster/base/kustomization.yaml
- Create: k8s/multicluster/base/backendconfig-app-a.yaml
- Create: k8s/multicluster/base/backendconfig-app-b.yaml
- Create: k8s/multicluster/base/mcs-app-a.yaml
- Create: k8s/multicluster/base/mcs-app-b.yaml
- Create: k8s/multicluster/base/mci.yaml
- Create: k8s/multicluster/tls/kustomization.yaml
- Create: k8s/multicluster/tls/mci-tls-patch.yaml
- Create: k8s/multicluster/https-redirect/kustomization.yaml
- Create: k8s/multicluster/https-redirect/frontendconfig.yaml
- Create: k8s/multicluster/https-redirect/mci-redirect-patch.yaml
- Create: k8s/overlays/config-us-central1/http/kustomization.yaml
- Create: k8s/overlays/config-us-central1/tls/kustomization.yaml
- Create: k8s/overlays/config-us-central1/https/kustomization.yaml

**Interfaces:**

- Consumes: stable app Service labels and Terraform output values GLOBAL_IP_ADDRESS, CLOUD_ARMOR_POLICY, and TLS_CERTIFICATE_NAME.
- Produces: HTTP-only, TLS-attached, and HTTPS-redirect configuration-cluster renders.
- Requires: both Fleet memberships, managed MCI, and us-central1 as configuration membership; Terraform owns the referenced IP, Cloud Armor policy, SSL policy, and Compute-managed certificate.

- [ ] **Step 1: Define BackendConfig and MCS resources**

Create cloud.google.com/v1 BackendConfigs app-a-backend and app-b-backend with request logging rate 1.0, CLOUD_ARMOR_POLICY, port 8080, five-second interval/timeout, healthy/unhealthy threshold 2, and 30-second connection draining. Their paths are /healthz and /health.

Create networking.gke.io/v1 MultiClusterServices app-a-mcs and app-b-mcs, selecting stable app labels and named http port, with the matching BackendConfig attached to port 8080. Both list exactly:

~~~yaml
clusters:
  - link: us-central1/gke-assessment-us-central1
  - link: us-east1/gke-assessment-us-east1
~~~

- [ ] **Step 2: Define HTTP, TLS, and redirect stages**

Create assessment-ingress as networking.gke.io/v1 MultiClusterIngress in assessment, annotated with GLOBAL_IP_ADDRESS. App A is the default backend; /app-a targets app-a-mcs:8080 and /app-b targets app-b-mcs:8080. The HTTP overlay has no certificate or FrontendConfig reference.

The TLS overlay adds only TLS_CERTIFICATE_NAME as the pre-shared certificate. The HTTPS overlay builds on TLS, creates networking.gke.io/v1beta1 FrontendConfig assessment-https with SSL policy schwab-assessment-tls and redirectToHttps.enabled: true, and attaches it to MCI. Do not create a ManagedCertificate.

- [ ] **Step 3: Build and validate all routing overlays**

~~~bash
kustomize build k8s/overlays/config-us-central1/http | kubeconform -strict -summary -ignore-missing-schemas -
kustomize build k8s/overlays/config-us-central1/tls | kubeconform -strict -summary -ignore-missing-schemas -
kustomize build k8s/overlays/config-us-central1/https | kubeconform -strict -summary -ignore-missing-schemas -
~~~

Expected: generic validation skips GKE CRDs whose schemas are not bundled locally. Review rendered YAML for exact MCI/MCS names, membership links, health paths, annotations, and ordering.

- [ ] **Step 4: Commit multi-cluster routing stages**

~~~bash
git add k8s/multicluster k8s/overlays/config-us-central1
git commit -m "feat: add staged MCI and MCS routing"
~~~

### Task 4: Provision Grafana and exactly three dashboard exports

**Files:**

- Create: k8s/base/grafana/kustomization.yaml
- Create: k8s/base/grafana/serviceaccount.yaml
- Create: k8s/base/grafana/secret-provider-class.yaml
- Create: k8s/base/grafana/deployment.yaml
- Create: k8s/base/grafana/service.yaml
- Create: k8s/base/grafana/networkpolicy.yaml
- Create: k8s/base/grafana/files/provisioning/grafana.ini
- Create: k8s/base/grafana/files/provisioning/datasources.yaml
- Create: k8s/base/grafana/files/provisioning/dashboard-providers.yaml
- Create: k8s/base/grafana/files/dashboards/assessment-overview.json
- Create: k8s/base/grafana/files/dashboards/multicluster-operations.json
- Create: k8s/base/grafana/files/dashboards/traffic-log-analysis.json
- Modify: k8s/overlays/us-central1/kustomization.yaml

**Interfaces:**

- Consumes: Terraform output values GRAFANA_GSA_EMAIL, GCP_PROJECT_NUMBER, GCP_PROJECT_ID, and BIGQUERY_DATASET, plus a Grafana digest, Cloud Monitoring, and the routed-log dataset.
- Produces: observability/grafana KSA, SecretProviderClass, one ClusterIP Grafana Deployment, datasource provisioning, and exactly three dashboard exports.
- Consumed by: automated smoke provisioning checks and committed dashboard-export evidence; Grafana is never an MCI target. The baseline does not grant a documented human Connect Gateway/RBAC path for interactive port-forward access.

- [ ] **Step 1: Resolve Grafana**

Resolve the selected Grafana digest before adding it to k8s/base/grafana/deployment.yaml; record it in `tools/images.env` and confirm plugin compatibility.

~~~bash
grafana_digest="$(crane digest docker.io/grafana/grafana:12.2.5-ubuntu)"
~~~

Add `GRAFANA_IMAGE=docker.io/grafana/grafana@${grafana_digest}` to `tools/images.env` using the actual resolved value and use that same reference verbatim in the Deployment. At this point the inventory has exactly the three required variables and no others.

- [ ] **Step 2: Add keyless Grafana and datasource provisioning**

Create KSA observability/grafana annotated with GRAFANA_GSA_EMAIL and SecretProviderClass mounting grafana-admin only at /var/run/secrets/grafana. Create a one-replica Recreate Deployment using the Grafana digest, UID/GID and fsGroup 472, RuntimeDefault seccomp, no privilege escalation, dropped capabilities, read-only root, and emptyDir volumes only for data, plugins, logs, and temporary files.

Set GF_SECURITY_ADMIN_PASSWORD__FILE=/var/run/secrets/grafana/admin-password, GF_PLUGINS_PREINSTALL_SYNC=grafana-bigquery-datasource@3.4.0, and GF_PATHS_PLUGINS=/var/lib/grafana/plugins. Use /api/health on 3000 for readiness/liveness. Create only ClusterIP Service and an internal NetworkPolicy; include the base only in us-central1.

Use configMapGenerator to package Grafana provisioning and dashboard files. Datasources define gcp-monitoring (stackdriver) and gcp-bigquery (grafana-bigquery-datasource) with metadata-server gce authentication, GCP_PROJECT_ID, location US, MaxBytesBilled: 1073741824, and restrictToAccessibleDatasets: true. Do not include a private key or credential file.

- [ ] **Step 3: Create dashboards and parse their JSON**

Create exactly three JSON exports. assessment-overview.json has exactly four root panels named Application error rate, Pod restarts, Request latency p50/p95/p99, and CPU and memory utilization, plus cluster, region, namespace, and application variables. Its BigQuery target uses SAFE_DIVIDE, 5xx counts, and $__timeFilter(timestamp); Monitoring targets use restart count, backend-latency percentiles 50/95/99, CPU, and memory. The supporting exports cover multi-cluster operations and traffic/log analysis; every BigQuery target includes $__timeFilter(timestamp).

~~~bash
kustomize build k8s/overlays/us-central1 | kubeconform -strict -summary -kubernetes-version 1.35.8 -ignore-missing-schemas -
find k8s/base/grafana/files/dashboards -maxdepth 1 -type f -name '*.json' -print0 | xargs -0 -n1 jq empty
~~~

- [ ] **Step 4: Commit Grafana provisioning and exports**

~~~bash
git add k8s/base/grafana k8s/overlays/us-central1 tools/images.env
git commit -m "feat: add provisioned Grafana dashboards"
~~~

### Task 5: Add BigQuery templates and authenticated dry-run handoff

**Files:**

- Create: observability/bigquery/README.md
- Create: observability/bigquery/queries/load-balancer-error-rate.sql
- Create: observability/bigquery/queries/application-logs.sql
- Create: observability/bigquery/queries/node-logs.sql
- Create: observability/bigquery/queries/control-plane-logs.sql
- Create: observability/bigquery/queries/load-balancer-logs.sql
- Create: observability/bigquery/queries/traffic-analysis.sql
- Create: observability/bigquery/queries/schema-discovery.sql

**Interfaces:**

- Consumes: GCP_PROJECT_ID, BIGQUERY_DATASET, and BigQuery parameters @start_time and @end_time.
- Produces: seven Standard SQL templates and a routed-log schema/cost guide.
- Requires: a Terraform-owned partitioned routed-log dataset with application, k8s_node, k8s_control_plane_component, and load-balancer logs.

- [ ] **Step 1: Write bounded SQL templates**

Use fully qualified project/dataset identifiers. Every data query filters timestamp BETWEEN @start_time AND @end_time; schema-discovery.sql reads INFORMATION_SCHEMA.COLUMNS and documents its metadata exception. Provide samples for load-balancer error rate, application, node, control-plane, and load-balancer logs, plus traffic analysis. Error rate uses SAFE_DIVIDE over 5xx results; traffic analysis groups status and safely parses latency.

- [ ] **Step 2: Document authenticated dry-run validation**

In observability/bigquery/README.md, explain table-per-log-name behavior, partitioned timestamp, first-record schema creation, likely versus discovered table names, query parameters, and Grafana's byte cap. Mark results deployment evidence pending. After OIDC authentication and deployment, the protected workflow discovers table names and runs bq query --dry_run --use_legacy_sql=false for each query with concrete project, dataset, and time parameters before any execution.

~~~bash
for query_file in observability/bigquery/queries/*.sql; do
  query_text="$(sed -e "s|\${GCP_PROJECT_ID}|${GCP_PROJECT_ID}|g" -e "s|\${BIGQUERY_DATASET}|${BIGQUERY_DATASET}|g" "${query_file}")"
  query_parameters=()
  if [[ "${query_file}" != */schema-discovery.sql ]]; then
    query_parameters+=(--parameter=start_time:TIMESTAMP:2026-09-01T00:00:00Z)
    query_parameters+=(--parameter=end_time:TIMESTAMP:2026-09-02T00:00:00Z)
  fi
  bq query --project_id="${GCP_PROJECT_ID}" --dry_run --use_legacy_sql=false "${query_parameters[@]}" "${query_text}"
done
~~~

- [ ] **Step 3: Keep SQL validation out of repository development**

Review each template for its timestamp predicate and source class while confirming repository development never runs bq. The authenticated dry-run is a future workflow step because it needs actual schema and Google credentials.

- [ ] **Step 4: Commit BigQuery query templates**

~~~bash
git add observability/bigquery
git commit -m "feat: add bounded BigQuery log queries"
~~~

## Account-Free Validation Boundary

Credential-free validation runs only Kustomize rendering for every access, regional, and configuration overlay; Kubeconform validation of supported schemas; and `jq empty` for each dashboard JSON file. Do not add language runtimes, bespoke policy files, Kind tests, custom validation scripts, or custom helper code. After the image inventory exists, `make security-scan` may be run as an optional advisory command; it is not an implementation gate.

These checks establish manifest renderability, ordinary Kubernetes schema conformance, and dashboard JSON syntax. The exact replica/HPA/PDB, routing, and dashboard-panel requirements remain manifest and documentation requirements reviewed with the rendered YAML and exports. The checks cannot establish GKE scheduling, HPA behavior, Secret Manager CSI access, Workload Identity authorization, MCI reconciliation, backend health, Cloud Armor attachment, regional failover, certificate activation, log ingestion/table names, Grafana plugin installation, datasource authentication, query validity against live schema, rendered data, or screenshots. Those remain deployment-evidence-pending until the future protected workflow records them.

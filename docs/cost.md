# Cost assumptions and controls

Pricing snapshot: 2026-09-02, public list prices in USD. This is an illustrative assessment model, not a quote or guarantee. Prices vary by region, currency, contract, billing-account-wide free usage/credits, traffic, resource adjustments, and future Google changes. Confirm with the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) immediately before deployment and use billing reports afterward.

## Baseline assumptions

- two regional GKE Autopilot clusters running 730 hours;
- App A: 3 Pods per region at 250m CPU/256 MiB request;
- App B: 3 Pods per region at 100m CPU/128 MiB request;
- Grafana: one primary-region Pod at 250m CPU/256 MiB request;
- 12 application Pods are direct MCI backends before HPA scaling;
- HTTP by reserved global IP, no Cloud DNS zone or managed certificate;
- light assessment traffic, no sustained drill, 30-day BigQuery partition expiry; and
- tiny versioned Terraform state retained after teardown.

Autopilot may adjust requests to platform minimums/ratios, so manifest arithmetic is not a billing guarantee.

## Illustrative fixed-feature subtotal

Google currently lists a $0.10 per-cluster-hour management fee and $3 per MCI/MCG backend Pod per 730-hour month. Under the assumptions:

```text
2 clusters × 730 hours × $0.10 = $146 cluster management
12 MCI backend Pods × $3       =  $36 MCI standalone feature
illustrative subtotal          = $182/month
```

This excludes every item below, including Autopilot Pod compute and load balancing. GKE's billing-account-wide $74.40 monthly credit may offset eligible Autopilot cluster management fees if it is available and not consumed elsewhere; do not assume it. The source and backend-Pod counting rules are on the current [GKE pricing page](https://cloud.google.com/kubernetes-engine/pricing).

## Additional billable components

| Component | Cost driver and assessment control |
| --- | --- |
| Autopilot workloads | Running Pod CPU, memory, and ephemeral-storage requests; right-size requests, keep HPA baseline 3, and stop promptly. |
| Global load balancer | Forwarding rules and inbound/outbound data processing/transfer; MCI charges do not include it. Review [Load Balancing pricing](https://cloud.google.com/load-balancing/pricing). |
| Cloud Armor Standard | Security policy, rules, and requests; current public prices include per-policy/rule time and $0.75 per million global-policy requests. Review [Cloud Armor pricing](https://cloud.google.com/armor/pricing). |
| Cloud NAT | Gateway use, processed GiB, external NAT IPs, and internet egress. Error-only logs reduce volume. Review [Cloud NAT pricing](https://cloud.google.com/nat/pricing). |
| Global IPv4 | Reserved/used external address pricing; teardown destroys the foundation address. Review [external IP pricing](https://cloud.google.com/vpc/network-pricing#ipaddress). |
| Cloud Logging | Stored log volume, vended network logs, and retention. Current public pricing includes the first 50 GiB/project/month for ordinary Logging storage but different treatment for vended network logs. Review [Observability pricing](https://cloud.google.com/products/observability/pricing). |
| BigQuery | Routed table storage plus bytes processed by queries. Partition expiry, bounded parameters, dry runs, selected columns, and Grafana's 1 GiB cap limit exposure. Review [BigQuery pricing](https://cloud.google.com/bigquery/pricing). |
| Monitoring/Prometheus | Metrics ingestion, samples, API reads, checks, and alerts according to metric type; dashboards themselves do not guarantee free queries. Review [Observability pricing](https://cloud.google.com/products/observability/pricing). |
| Secret Manager | Active versions and access operations; the baseline creates two versions, but billing-account-wide free allowances are not guaranteed available. Review [Secret Manager pricing](https://cloud.google.com/secret-manager/pricing). |
| Cloud DNS, optional | Managed-zone hours and queries when Terraform manages DNS; external registrars charge separately. Review [Cloud DNS pricing](https://cloud.google.com/dns/pricing). |
| State bucket | Standard object storage, versioned noncurrent state, and operations. Review [Cloud Storage pricing](https://cloud.google.com/storage/pricing). |
| Data transfer | Internet egress, inter-region paths, registry pulls through NAT, and other network traffic; test traffic should remain bounded. |

## Cost controls

- Require an estimate and named cost owner before deployment; configure project budget alerts outside this repository.
- Deploy only through manual non-cancelling workflows and tear down immediately after evidence collection.
- Keep both optional drills false unless a reviewed evidence plan requires them. HPA temporarily adds backend Pods and compute.
- Keep SQL time/partition filters narrow, dry-run before actual queries, and avoid `SELECT *`.
- Retain logs for the assessment's 30-day window only; review duplicate storage in Cloud Logging and BigQuery.
- Keep Cloud Armor WAF rules in preview until observed/tuned; unexpected request volume still costs.
- Inspect orphaned MCI controller resources during teardown; load-balancer deletion latency can extend charges.

## After teardown

Normal teardown removes MCI/controller load-balancer resources, namespaces, clusters, NAT, address, Armor, BigQuery dataset/sink, secrets, optional DNS/certificate, and other platform/foundation resources. The foundation-only recovery path skips never-created platform/controller classes. Teardown intentionally retains the project, WIF pool/provider, deployer identity/IAM, enabled bootstrap APIs, versioned state bucket, and any bootstrap/foundation/platform state objects and versions that were created.

Those retained control-plane identities do not run workloads. A few small state objects normally make dormant spend effectively zero at ordinary billing precision, but Cloud Storage bytes/versions/operations and future price changes mean literal $0 cannot be promised. Verify the post-teardown billing/residual report. Full bootstrap decommission is a separate reviewed operation not automated here.

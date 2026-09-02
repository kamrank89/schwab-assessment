# Optional DNS and TLS

DNS is not required for the default HTTP verification: the smoke script calls the Terraform-reserved global IPv4 address directly. A Google-managed certificate needs a hostname you control and public DNS resolving that hostname to the reserved address; therefore the managed-certificate/HTTPS path requires DNS even if Terraform does not manage the record.

## Configuration choices

### Existing externally managed DNS

First deploy and verify the HTTP baseline, record the reserved global IPv4, create the external A record, and wait for public resolution. Then set:

```bash
# GITHUB REPOSITORY MUTATION; the next deployment mutates cloud resources and adds cost.
gh variable set GCP_ENABLE_HTTPS --repo OWNER/REPO --body true
gh variable set GCP_MANAGE_DNS --repo OWNER/REPO --body false
gh variable set GCP_CREATE_DNS_ZONE --repo OWNER/REPO --body false
gh variable set GCP_DNS_NAME --repo OWNER/REPO --body app.example.com
gh variable set GCP_DNS_ZONE_NAME --repo OWNER/REPO --body ''
gh variable set GCP_DNS_ZONE_DNS_NAME --repo OWNER/REPO --body ''
```

Creating the external A record is a DNS mutation outside Terraform; record who owns it and remove it during teardown. Do not enable HTTPS in the first HTTP deployment because the workflow has no pause in which to create the external record before its certificate wait.

### Existing Cloud DNS zone

Use two deployments so DNS is established before the certificate wait. In phase 1:

```bash
# GITHUB REPOSITORY MUTATION; deployment creates/updates the A record but not a certificate.
gh variable set GCP_ENABLE_HTTPS --repo OWNER/REPO --body false
gh variable set GCP_MANAGE_DNS --repo OWNER/REPO --body true
gh variable set GCP_CREATE_DNS_ZONE --repo OWNER/REPO --body false
gh variable set GCP_DNS_NAME --repo OWNER/REPO --body app.example.com
gh variable set GCP_DNS_ZONE_NAME --repo OWNER/REPO --body existing-zone
gh variable set GCP_DNS_ZONE_DNS_NAME --repo OWNER/REPO --body ''
```

Deploy, verify the A record publicly resolves to the reserved IP, then set `GCP_ENABLE_HTTPS=true` and deploy again. The second deployment creates and waits for the certificate.

### Terraform-created Cloud DNS zone

This also needs two phases because registrar delegation can occur only after the new zone exposes its name servers. In phase 1:

```bash
# GITHUB REPOSITORY MUTATION; deployment creates a billable public zone and A record, not a certificate.
gh variable set GCP_ENABLE_HTTPS --repo OWNER/REPO --body false
gh variable set GCP_MANAGE_DNS --repo OWNER/REPO --body true
gh variable set GCP_CREATE_DNS_ZONE --repo OWNER/REPO --body true
gh variable set GCP_DNS_NAME --repo OWNER/REPO --body app.example.com
gh variable set GCP_DNS_ZONE_NAME --repo OWNER/REPO --body assessment-zone
gh variable set GCP_DNS_ZONE_DNS_NAME --repo OWNER/REPO --body 'example.com.'
```

Deploy phase 1, obtain the zone name servers, update registrar delegation, and wait until the public A record resolves to the reserved IP. Delegation is an external DNS mutation and may incur registrar cost. Then set `GCP_ENABLE_HTTPS=true` and deploy phase 2.

## Deploy and verify

Dispatch each `deploy.yml` phase with both drills false. **Cloud mutation and cost:** Terraform creates the managed certificate and optional DNS resources; Kustomize first applies TLS, waits up to 45 minutes for certificate activation, then applies the HTTP-to-HTTPS redirect and waits for both HTTP 3xx and HTTPS 2xx.

Do not enable HTTPS with an unowned or non-resolving name. Verify authoritative A/NS records, the certificate's managed status, and both paths. Do not claim TLS evidence until the authorized smoke run records it. Troubleshooting is in [operations/troubleshooting.md](../operations/troubleshooting.md).

To return to HTTP, set all three booleans false, clear DNS strings, and dispatch deployment. **Cloud mutation:** this removes Terraform-managed certificate/DNS resources and returns MCI to the HTTP overlay; expect reconciliation time and verify before closing the change.

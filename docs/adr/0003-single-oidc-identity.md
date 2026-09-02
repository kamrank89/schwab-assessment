# ADR 0003: Use one OIDC-federated deployer identity for the assessment

- Status: accepted for assessment only
- Date: 2026-09-01

## Context

Manual foundation, platform, workload, verification, and teardown jobs need short-lived Google Cloud credentials. Creating several least-privilege pipelines would add governance surface beyond the assessment while making the bootstrap and demonstration harder to reproduce.

## Decision

Bootstrap one `assessment-deployer` Google service account. GitHub Actions may impersonate it only through WIF from the configured immutable repository and owner IDs with the exact `main` branch subject. No service-account key is created. Both deploy and teardown use this same identity.

## Consequences

The approach is keyless and easy to operate, but the identity holds broad project and state-bucket roles. A compromised allowed workflow can affect networking, GKE, Fleet, IAM, secrets, logging, BigQuery, DNS, and teardown. GitHub branch protection and reviewed workflow changes therefore matter materially.

Production should separate bootstrap, foundation, platform, namespace workload, read-only verification, and teardown identities; narrow roles and WIF subjects; and require independent protected-environment approvals. That separation is recommended, not implemented or claimed here.

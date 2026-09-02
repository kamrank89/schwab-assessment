# ADR 0002: Use MCI/MCS for the rubric and plan a Gateway API migration

- Status: accepted with required future migration
- Date: 2026-09-01

## Context

The supplied assessment explicitly calls for Multi Cluster Ingress or Multi Cluster Services and global routing/failover. GKE also offers multi-cluster Gateway resources aligned with Kubernetes Gateway API.

## Decision

Implement MultiClusterIngress and MultiClusterService now because they map directly to the rubric and provide a single global VIP, path routing, health-based multi-region backends, Cloud Armor through BackendConfig, and an optional managed-certificate path. The `us-central1` Fleet membership is the config membership.

This is not the terminal production API choice. Before production adoption, migrate north-south routing to GKE multi-cluster Gateway API after validating feature parity for static IP, TLS, redirects, Cloud Armor, health checks, logging, and teardown ownership.

## Migration outline

1. Inventory the current MCI controller resources and capture live HTTP/HTTPS and backend-health evidence.
2. Enable and validate the supported multi-cluster Gateway controller/API in a non-production fleet.
3. Model `Gateway`, `HTTPRoute`, and multi-cluster Services with equivalent routes, policies, certificate, and static-address behavior.
4. Run parallel or staged traffic tests where supported; define rollback before changing DNS or the serving frontend.
5. Cut over under change control, verify both regions and failure behavior, then remove MCI-owned resources only after ownership is unambiguous.
6. Replace this ADR and the lifecycle scripts with the proven Gateway implementation.

## Consequences

The current solution is easy to explain against the rubric but carries a deliberate migration obligation. MCI controller-created load-balancer resources require explicit inventory and reverse-order cleanup. Multi-cluster Gateway is also separately billed, so migration is an API and operability decision, not an assumption of lower cost.

See Google's current [multi-cluster load-balancing guidance](https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-ingress) and [multi-cluster networking migration guide](https://cloud.google.com/kubernetes-engine/docs/how-to/migrate-gke-multi-cluster).

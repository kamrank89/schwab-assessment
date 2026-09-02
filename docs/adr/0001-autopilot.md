# ADR 0001: Use regional GKE Autopilot clusters

- Status: accepted
- Date: 2026-09-01

## Context

The assessment needs two reproducible regional clusters and scalable multi-pod workloads, but not custom node-pool operations. The focus is architecture, safe delivery, multi-cluster routing, and observability.

## Decision

Create regional Autopilot clusters in `us-central1` and `us-east1`. Use private nodes, VPC-native networking, IAM-authorized DNS endpoints, Workload Identity Federation for GKE, Secret Manager CSI integration, the Regular release channel, weekly maintenance windows, and explicit Pod resource requests.

## Consequences

Autopilot removes node-pool sizing and upgrade code, applies a managed security posture, and bills general-purpose workloads primarily from Pod requests. It also constrains node-level customization and can adjust requests to platform minimums. The architecture still incurs cluster management, workload compute, networking, MCI, logging, and other service charges; it is not presented as free tier.

For production, validate workload compatibility, release-channel and maintenance policy, resource-request economics, quotas, disruption behavior, organization policies, and regional capacity with real workload tests.

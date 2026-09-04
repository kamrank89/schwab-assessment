# ADR 0004: Use digest-pinned public images and Secret Manager runtime mounts

- Status: accepted for assessment
- Date: 2026-09-01

## Context

The assessment evaluates platform design rather than application development. Building and publishing custom images would introduce source, registries, build identities, and attestations outside the requested scope.

## Decision

Use public `nginxinc/nginx-unprivileged`, `traefik/whoami`, and Grafana images pinned by immutable SHA-256 digest in `tools/images.env` and Kubernetes manifests. Run containers as non-root with dropped capabilities and read-only root filesystems where supported. Store the App A demonstration value and Grafana admin password in Secret Manager, grant each runtime identity access only to its own secret, and mount `latest` through the GKE Secret Manager CSI provider. App B has no secret access and does not mount a service-account token.

Deployment creates an initial random secret version only when no enabled version exists. Values are piped on standard input and are not placed in Terraform, GitHub variables, arguments, logs, or artifacts.

## Consequences

Digest pinning makes the selected bytes stable but does not prove provenance, absence of vulnerabilities, or ongoing upstream support. Dependabot covers Action pins; image digest refresh remains a reviewed manual change. `make security-scan` runs Trivy only when independently installed and is advisory, not a validation or deployment gate.

Because these are third-party demonstration images, application-level Trace, Profiler, rich error formatting, SBOM/attestation policy, and source-to-image provenance are outside the implemented boundary. Production should use owned images, a private registry, signed provenance, policy enforcement, vulnerability SLAs, and explicit telemetry instrumentation.

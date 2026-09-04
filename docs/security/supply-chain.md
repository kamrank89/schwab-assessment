# Supply-chain controls

## Implemented

- Application and Grafana images are referenced by full `sha256` digest in manifests and `tools/images.env`; no mutable tag determines deployed bytes.
- Third-party GitHub Actions are pinned to 40-character commit SHAs. Dependabot opens weekly GitHub Actions update pull requests; it does not auto-merge.
- Terraform providers and standard command-line tools have committed lock/checksum inventories and fixed versions.
- Containers run as non-root, drop Linux capabilities, disable privilege escalation, use RuntimeDefault seccomp, and use read-only root filesystems where supported.
- `make validate` uses standard Terraform, Kustomize, Kubeconform, ShellCheck, actionlint, and `jq`; it adds no custom parser/test framework.

## Image review

`crane` is installed for a human to resolve and inspect image digests. Digest pinning protects reproducibility, not trust. Before updating an image:

1. verify the upstream publisher and intended release;
2. resolve multi-architecture manifests and the selected platform digest;
3. review release notes and vulnerabilities;
4. update `tools/images.env` and every manifest together;
5. run account-free validation and a non-production rollout; and
6. record approval and rollback digest.

## Optional advisory scan

```bash
# Local/network activity only; advisory and non-gating. Trivy is not installed by make tools.
make security-scan
```

If Trivy is absent the target prints a skip message and succeeds. If installed, it scans Terraform/Kubernetes configuration and the three pinned images for HIGH/CRITICAL findings, ignoring unfixed image findings. Results require human triage; a clean scan is not a provenance or runtime guarantee.

## Production additions

Use owned application source, hermetic builds, a private registry, SBOMs, signed provenance/attestations, vulnerability SLAs, admission policy such as Binary Authorization, dependency licensing review, and separated build/deploy identities. Those controls are not implemented or claimed by this assessment.

# Live evidence record template

Copy this template for each authorized deployment, optional exercise, teardown, or redeploy. A row may become `verified-live` only after every required metadata field is complete, the result directly proves that row, redaction is reviewed, and the artifact is retrievable. `verified-live` is reserved for completed records; it is not a repository-development status.

## Record metadata

| Field | Required value |
| --- | --- |
| Evidence ID | Stable identifier, for example `20260902T120000Z-smoke` |
| Scope | One bounded claim: cluster/Fleet, replicas, routing, BigQuery, Grafana, HTTPS-to-HTTP transition, drill, teardown, or residuals |
| Status | `verified-live` only after review; otherwise `deployment-evidence-pending` |
| Start time UTC | RFC 3339 seconds |
| End time UTC | RFC 3339 seconds |
| Commit SHA | Full 40-character deployed commit |
| Workflow URL | Exact GitHub Actions run URL; use `not-applicable` only for an approved local read-only collection |
| Actor | GitHub actor or authorized operator identifier |
| Reviewer/approver | Independent reviewer and approval reference |
| Project/regions | Approved non-secret identifiers |
| Command | Exact command or workflow step that produced the result |
| Expected result | Predeclared measurable status/count/class |
| Actual result | Minimal redacted status/count/class; no inference beyond output |
| Artifact location | Durable approved URI/path and retention period |
| Redaction note | What was removed and who reviewed redaction |

## Command and result

```text
Command/workflow step:

Exit status:

Expected:

Actual redacted result:

Interpretation limited to:
```

Do not paste secret values, tokens, kubeconfigs, Terraform state or plan content, HTTP bodies, raw BigQuery rows or schema-discovery payloads, full logs, user IPs, or unrelated project inventory. Prefer counts, resource names already public in code, status classes, UTC windows, and pass/fail summaries.

## Artifact inventory

| Artifact | Location | SHA-256 if exported | Retention | Redaction reviewed by |
| --- | --- | --- | --- | --- |
| Redacted workflow/script report |  |  |  |  |
| Screenshot or dashboard export, if applicable |  |  |  |  |
| Query or teardown summary, if applicable |  |  |  |  |

## Claim checklist

- [ ] The command ran against the commit and project named above.
- [ ] The output directly proves only the stated scope.
- [ ] Expected and actual values are recorded, including failures.
- [ ] Restoration is proven for any mutating exercise.
- [ ] The artifact is redacted, reviewed, retrievable, and retention is known.
- [ ] Related but unproven status rows remain unchanged.

## Review decision

```text
Reviewer decision: approve / reject
Reviewed at UTC:
Reason:
Status rows permitted to change:
```

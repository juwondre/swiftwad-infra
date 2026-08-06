# Operations — credentials, expiry, and the things that fail silently

The platform's daily paths are all SSO. Everything below is the small set of long-lived credentials that remain, what they unlock, and how they fail. **The failures here are quiet ones** — nothing pages you when a token expires; deployments simply stop and everyone assumes someone else changed something.

## Break-glass inventory

Every one of these should live in the team password manager, not in a shell history or a file on one laptop.

| Credential | Where it lives | Unlocks | Rotation |
|---|---|---|---|
| **ArgoCD `admin`** | `argocd-initial-admin-secret` in the `argocd` namespace | Full ArgoCD, bypassing SSO | Rotate via `argocd account update-password`; the secret may be deleted after storing it — the account keeps working |
| **Kargo `admin`** | password hash in the helm release; plaintext only where you stored it | Full Kargo, bypassing SSO | Re-run the `kargo` bootstrap phase with a new `KARGO_ADMIN_PASSWORD` |
| **Grafana `admin`** | `grafana` secret, key `admin-password` | Full Grafana, bypassing SSO | `kubectl delete secret grafana` + re-sync, or set explicitly in values |
| **Bootstrap IAM user** | AWS access keys (if kept) | Cluster-admin on every cluster, terraform apply | Prefer deleting it once SSO operators are declared in `operator_principal_arns` |
| **AWS account root** | account credentials | Account ceremonies only | Never used for daily work; cannot access clusters at all (AWS design) |

**Rule**: after SSO is live, these exist for the day SSO is broken. If one is being used routinely, something is misconfigured.

## Automation credentials — the expiry traps

| Credential | Purpose | Failure mode | Symptom |
|---|---|---|---|
| **ArgoCD gitops read token** (private repos only) | ArgoCD clones the gitops repo | **Expires** — GitHub org policy caps PAT lifetime | Root app stops syncing; *deployments silently stop landing* while everything looks green-ish |
| **Kargo deploy key** (gitops repo, write) | Kargo pushes promotion commits | Revoked/deleted | Promotions fail at the git-push step |
| **Atlantis GitHub token** | Plan/apply comments, webhook auth | Expires or user leaves | Infra PRs get no plan comment at all |
| **GitHub OAuth app secrets** (ArgoCD Dex, Grafana) | SSO | Rotated/revoked | Login fails for everyone; break-glass admin still works |
| **Cloudflare/DNS token** (if not Route53) | external-dns record management | Expires, or IP filter drifts after a NAT change | DNS records stop updating; existing records keep resolving, so nothing obviously breaks |

### The one that will bite you

The **ArgoCD read token** is the most dangerous because its failure is invisible: ArgoCD keeps serving the last-known state, applications look healthy, and only *new* commits stop arriving. Mitigations, in order of value:

1. **The alert** (shipped in `alert-rules.yaml`): `ArgoCDRepoSyncStale` fires when the root application has not reconciled successfully for an hour — the reliable canary for a dead credential.
2. **Calendar the expiry** the day you mint the token. GitHub caps org PAT lifetime; whatever you chose, put the date in a shared calendar with the remediation command attached.
3. **Prefer a GitHub App** over a PAT for the real environment — App installation tokens refresh automatically and don't carry a human's lifetime.

Remediation when it happens (60 seconds):

```sh
kubectl -n argocd delete secret repo-gitops
kubectl -n argocd create secret generic repo-gitops \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<org>/<gitops-repo> \
  --from-literal=username=x-access-token \
  --from-literal=password='<new-token>'
kubectl -n argocd label secret repo-gitops argocd.argoproj.io/secret-type=repository
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=hard --overwrite
```

## Routine checks worth automating later

- `terraform plan` clean (no drift) — Atlantis shows this on every infra PR anyway
- All applications Synced/Healthy — the Platform delivery dashboard's top row
- Remote-write delivering: `prometheus_remote_storage_samples_failed_total` at zero
- No credential within 30 days of expiry

## When something stops deploying — triage order

1. Is the root app synced? `kubectl -n argocd get app root` → if `Unknown` with an auth condition, it's the read token (above).
2. Did CI build and push? Check the run and `aws ecr describe-images`.
3. Did Kargo discover freight? `kubectl -n <project> get freight` → if not, check the warehouse's condition and the controller's IRSA.
4. Did the promotion run? `kubectl -n <project> get promotions` → a failed promotion is a **corpse, not a retry**: delete it, then refresh the stage.
5. Is the app itself unhealthy? That's the vendor's code, not the platform — the Service overview dashboard and pod logs.

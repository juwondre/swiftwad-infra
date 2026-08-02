# Platform setup — vendor-isolated GitOps delivery

How to stand up the entire platform from nothing: EKS clusters, ArgoCD (hub-spoke), Kargo promotion, Atlantis for infra PRs, and the CI trust wiring. This documents exactly how the POC was built, including everything that bit us, so the real project doesn't rediscover it.

`scripts/bootstrap.sh` automates phases 2–7. Adjust the config block at the top of the script, run it phase by phase, done. This document explains what each phase does and why.

## Architecture

```
vendor repo (code only)          gitops repo (write-closed to vendors)      infra repo (invisible to vendors)
      |                                    ^         ^                            |
      | push to main                       |         |                            | PR -> Atlantis plan
      v                                    |         |                            | comment -> apply
GitHub Actions ──OIDC──> ECR push          |         |                            v
                          |                |         |                        Terraform
                          v                |         |                     (VPC, EKS, IAM, ECR)
                   Kargo Warehouse ────────┘         |
                   (polls every 30s)            ArgoCD hub (staging cluster)
                          |                          |
              dev Stage: auto-promote          syncs dev (spoke) + staging (in-cluster)
              staging Stage: human gate
```

Trust boundaries:
- Vendors write only to their app repo. Their CI can only push one image to one ECR repo (OIDC role condition).
- Only Kargo commits to the gitops repo (its own deploy key). Promotion history = git log.
- Only Atlantis (and break-glass humans) applies the infra repo. Vendors can't read it.

## Prerequisites

- Tools: `terraform >= 1.9`, `helm 3`, `kubectl`, `aws` CLI v2, `gh` CLI (authenticated as the org/bot account), `jq`, `openssl`, `htpasswd`
- An AWS account + IAM principal with admin (bootstrap only; day-2 runs through Atlantis)
- GitHub org (or account) to host the three repos
- **Check your EC2 On-Demand vCPU quota first**: `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`. Each t3.medium consumes 2 vCPUs. The POC fits in 10 vCPUs of headroom (5 nodes). Fresh accounts often have 16 total — request an increase *before* you start (auto-approval is not guaranteed; ours went to human review).
- **Check GitHub billing is in good standing** — a locked account silently refuses to start any Actions job, even on public repos ("account is locked due to a billing issue" in check-run annotations).

## Phase 1 — Repos

Three repos, and the boundary between them *is* the security model:

| Repo | Contents | Vendor access |
|---|---|---|
| `<org>/<infra-repo>` | Terraform, this doc, bootstrap script | none |
| `<org>/<gitops-repo>` | Helm chart template, env values, ArgoCD + Kargo config | read at most |
| `<org>/<app-repo>` (per service) | Source + Dockerfile + build workflow | write |

## Phase 2 — Terraform state + core infra

1. Versioned S3 bucket for state (name in the script config). Backend uses `use_lockfile = true` (native S3 locking, no DynamoDB table needed on TF >= 1.9).
2. `terraform apply` creates: one VPC (2 AZs, single NAT for non-prod), one EKS cluster per environment, ECR repo per service (immutable tags + scan-on-push), and the IAM roles below.
3. No AWS profile is hardcoded — laptops export `AWS_PROFILE`, in-cluster components use IRSA.

**Gotcha — GitHub OIDC sub claims are ID-pinned.** GitHub now issues `sub` as `repo:owner@<owner-id>/repo@<repo-id>:ref:...`, not `repo:owner/repo:ref:...`. A trust policy with only the plain form fails `AssumeRoleWithWebIdentity` with a bare "Not authorized". Get the real prefix from `gh api repos/<org>/<repo>/actions/oidc/customization/sub` (field `sub_claim_prefix`) and trust **both** forms (see `github-oidc.tf`). Also: if the account already has the `token.actions.githubusercontent.com` OIDC provider, reference it with a `data` source instead of creating it.

**Gotcha — IAM propagation.** A trust-policy change can take ~30–60s to reach STS. A CI run dispatched immediately after `apply` may still fail; wait and retry before digging deeper.

## Phase 3 — ArgoCD hub + spokes

1. Helm-install ArgoCD on the hub cluster (we use staging; a dedicated mgmt cluster is the prod-grade choice) with the values in `<gitops-repo>/bootstrap/argocd-values.yaml` — includes vendor RBAC (below).
2. Register each spoke **declaratively**: create a `ServiceAccount` + `ClusterRoleBinding` + long-lived token on the spoke, then a cluster `Secret` (label `argocd.akuity.io/secret-type: cluster`) on the hub with the spoke's endpoint, CA, and bearer token. The `argocd cluster add` CLI does the same thing but needs a working gRPC path to the API server; the declarative route always works and is reproducible.
3. Cross-cluster networking: the hub must reach each spoke's API server on 443. Same-VPC clusters need an ingress rule on the spoke's cluster security group (`aws_vpc_security_group_ingress_rule.hub_to_dev_api` in `eks.tf`). Without it, apps stick at `Unknown` with `dial tcp ... i/o timeout`.
4. Apply the root app-of-apps (`argocd/root-app.yaml`); everything else (AppProjects, Applications) syncs from git. If child apps briefly complain `project ... does not exist`, it's an ordering blip — hard-refresh or restart the application controller once.

**Vendor read-only access** (`configs.rbac` in the ArgoCD values):
```
p, role:vendor-readonly, applications, get, <project>/*, allow
p, role:vendor-readonly, logs, get, <project>/*, allow
g, <sso-group-or-local-account>, role:vendor-readonly
policy.default: ""
```
One AppProject per vendor; the empty default policy means anything not granted is denied. Verified behavior: vendors list/see only their project's apps, can tail logs, get 403 on everything else including sync of their own apps.

## Phase 4 — Kargo (promotion)

1. Install cert-manager (Kargo's webhook certs), then Kargo, on the hub cluster. Set `api.adminAccount.passwordHash` (bcrypt via `htpasswd -bnBC 10`), `api.adminAccount.tokenSigningKey`, and the controller's IRSA annotation.
2. IRSA role for the controller: ECR read (`DescribeImages`, `BatchGetImage`, `GetDownloadUrlForLayer`, `ListImages`) on the service repos + `GetAuthorizationToken` (see `kargo.tf`).
3. Apply per-service delivery config from `<gitops-repo>/kargo/`: `Project` + `ProjectConfig` (dev auto-promotion), `Warehouse` (ECR subscription), `Stage` dev + staging (+ prod later — same shape, one more gate).
4. Git credentials: a write deploy key on the gitops repo, stored as a Secret in the project namespace labeled `kargo.akuity.io/cred-type: git`, `repoURL` matching the promotion steps' clone URL exactly.
5. Annotate each ArgoCD Application with `kargo.akuity.io/authorized-stage: <project>:<stage>` or the `argocd-update` step will refuse to touch it.

**Freshness**: `Warehouse.spec.interval: 30s` makes vendor pushes visible in dev within ~1 minute of the image landing in ECR (CI build time dominates, not Kargo). ECR emits no webhooks; if you want true push-based discovery later, route EventBridge ECR "image push" events to Kargo's external webhooks server through a public endpoint (ALB + TLS). At 30s polling for a handful of repos, the DescribeImages cost is noise — polling is the simpler system.

**Gotchas:**
- A Kargo `Project` owns a namespace named after itself **on the hub cluster**. Don't name the project after the app if the app also deploys to a same-named namespace on that cluster (we use `<app>-delivery`).
- Image tags are git SHAs, so `imageSelectionStrategy: NewestBuild` — the default SemVer strategy finds nothing.
- Creating a `Promotion` requires the RBAC verb `promote` on the Stage. **EKS access-policy admin does not satisfy custom verbs** — bind an explicit Role (`stage-promoter`) to whoever approves promotions. This is also your release-manager permission: grant it to humans for staging/prod, to nobody else.
- CI must NOT also write image tags to the gitops repo once Kargo owns promotion — one writer per file, or they fight.

## Phase 5 — Atlantis (infra PRs)

1. IRSA role for the Atlantis pod (`atlantis.tf`). POC uses `AdministratorAccess` because this terraform manages IAM/VPC/EKS; scope with a permissions boundary in the real project.
2. Helm-install with: `orgAllowlist=github.com/<org>/<infra-repo>`, GitHub credentials, a webhook secret, `service.type=LoadBalancer` (or ingress + TLS in the real project), and the IRSA annotation.
3. Create the repo webhook pointing at `http(s)://<atlantis-host>/events` with events `push`, `pull_request`, `pull_request_review`, `issue_comment`, sharing the webhook secret.
4. `atlantis.yaml` at the infra repo root: autoplan on `*.tf` in `terraform/`. Add `apply_requirements: [approved, mergeable]` when there's more than one operator.

Flow: open a PR touching terraform → Atlantis comments the plan → reviewer approves → comment `atlantis apply` → Atlantis applies with a state lock and reports back → merge. Nobody runs `terraform apply` from a laptop anymore (keep the bootstrap principal as break-glass).

**Real project**: replace the personal-token GitHub auth with a GitHub App (finer permissions, no user coupling), put Atlantis behind ingress with TLS, and restrict the webhook source to GitHub's IP ranges.

**Gotcha — Atlantis becomes the "cluster creator".** The EKS module's `enable_cluster_creator_admin_permissions` grants admin to *whoever runs terraform*. The first Atlantis apply replaces the human bootstrap principal's access entry with the Atlantis role — instantly locking every laptop out of kubectl on all clusters. Restore with `aws eks create-access-entry` + `associate-access-policy` (EKS API, needs only IAM). In the real project, declare explicit `access_entries` for your operator roles in the module config from day one instead of relying on creator permissions, so admin access is code, not a side effect of who ran apply last.

**Gotcha — Atlantis needs storage.** EKS ships no CSI driver; the chart's default PVC stays `Pending` forever. Install the `aws-ebs-csi-driver` addon (see `ebs-csi.tf`) before enabling `volumeClaim`, or run stateless with an `emptyDir` mounted at `/atlantis-data` (loses locks/plans on pod restart — fine for POC, not for a busy team).

## Phase 6 — Per-service CI wiring

For each vendor service:
1. ECR repo + OIDC role (Terraform — copy the `sample_app` pattern, one role per repo, ECR-push-only, both sub-claim forms).
2. Build workflow in the app repo: checkout → OIDC assume role → build → push `$GITHUB_SHA`. Nothing else — no gitops access, no deploy keys.
3. Values file in the gitops repo (`envs/<env>/<app>.yaml`) from the app-template chart; conformance enforced by the chart's `values.schema.json` (ECR-only images, no `latest`, ports > 1024, mandatory probes/resources).
4. Kargo Warehouse + Stages for the service (copy `kargo/`, adjust names/paths).

## Phase 7 — Verify

- CI: push a commit → green run → image in ECR tagged with the SHA
- Kargo: freight appears within ~1 min → dev auto-promotes → gitops log shows a commit authored by Kargo → ArgoCD dev app Synced/Healthy
- Gate: staging unchanged until a `Promotion` (UI button or CR); after approval staging serves the new build
- Vendor RBAC: vendor account sees only its apps, can tail logs, 403 on sync
- Atlantis: open a whitespace PR in the infra repo → plan comment appears → `atlantis apply` works

## Teardown

```sh
helm -n atlantis uninstall atlantis; helm -n kargo uninstall kargo; helm -n cert-manager uninstall cert-manager
# delete any Service of type LoadBalancer first or its ELB/ENIs block VPC deletion
terraform destroy
# state bucket, deploy keys, and webhook survive; remove by hand if truly done
```

## Cost while running (POC sizing, us-east-1)

~$146/mo EKS control planes (2), ~$90–120/mo nodes (3–4 × t3.medium), ~$35/mo NAT, ~$18/mo Atlantis ELB. Roughly **$300/mo**; `terraform destroy` when idle — rebuild is ~30 minutes with the bootstrap script.

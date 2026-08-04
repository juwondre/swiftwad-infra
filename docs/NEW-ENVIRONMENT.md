# Standing up a new environment (new AWS account, new repo names)

The migration path for pointing this platform at a fresh AWS account with your own naming. After the parameterization pass, the work is: **fill a naming sheet, toggle two flags, run the phases, render the gitops repo once.** Companion detail lives in `SETUP-GUIDE.md`; this file is the delta for *new account + new names*.

## 0. The naming sheet

| Key | POC value | Yours |
|---|---|---|
| Account ID | 905418331655 | |
| Region | us-east-1 | |
| `cluster_prefix` | swiftwad | |
| GitHub owner (repos) | juwondre | |
| GitHub org (SSO gate) | swiftwad | |
| Repos | swiftwad-infra / -gitops / -sample-api | |
| Domain | swiftwad.com | |
| Service + ECR name | swiftwad-sample-api / sample-api | |

## 1. Account prep (before code)

- vCPU quota ≥ 10 free (`L-1216C47A`); request 32 on day one — approval can take a day.
- Identity Center: admin group assigned to the account; note the resulting role's **full pathed ARN** for `operator_principal_arns`.
- `dig +short NS <domain>` — learn who actually serves DNS; this picks the external-dns provider and where ACM validation CNAMEs go.
- GitHub org: 2FA required, base repo permission `none`, no member public repos (the org IS the login gate).

## 2. Repos first (Terraform needs their identity)

Create the renamed repos from the POC code, then capture each service repo's **ID-pinned OIDC prefix** — it encodes the new org/repo IDs:

```sh
gh api repos/<owner>/<service-repo>/actions/oidc/customization/sub --jq '.sub_claim_prefix'
```

## 3. Infra repo: variables, not find-replace

Everything account/name-shaped is now a variable with the POC value as default. Set yours in `terraform.tfvars` (or the bootstrap config block):

```hcl
region                      = "..."
cluster_prefix              = "..."
domain                      = "..."
service_name                = "..."          # -> gh-actions-<service_name> role
ecr_repo_name               = "..."
sample_app_repo             = "<owner>/<service-repo>"
sample_app_repo_id_pinned   = "<from step 2>"
operator_principal_arns     = ["<deploy user or pathed SSO admin role>"]
viewer_principal_arns       = []
create_github_oidc_provider = true            # fresh accounts have no GitHub OIDC provider
create_wildcard_cert        = true            # no pre-existing cert to reuse
```

Two things variables can't reach:
- **Backend bucket** (`versions.tf`) — backend blocks forbid variables; edit the bucket/region literals.
- The bootstrap CONFIG block mirrors the sheet; keep them consistent.

After the first apply, place the `acm_validation_records` output at your DNS host (cert stays `PENDING_VALIDATION` until then), and everything the gitops repo needs is in one output:

```sh
terraform output -json platform_config
```

## 4. Gitops repo: one render, then review the diff

The gitops manifests intentionally contain concrete values (GitOps means the repo IS the environment). Migration is a one-shot rewrite driven by two env files:

```sh
cd <gitops-repo>
cp environments/poc.env environments/prod.env   # fill prod.env from the naming sheet + platform_config
hack/render-environment.sh environments/poc.env environments/prod.env
git diff        # REVIEW — this is the whole migration diff, then commit by PR
```

`poc.env` records the exact literals currently in the repo; the script replaces each old literal with your new value, longest-first (so `swiftwad-staging` rewrites before `swiftwad` can clobber it). It is a one-shot tool: after rendering, the anchors are gone by design.

## 5. Service repos: GitHub Variables, not editing workflows

The CI workflow reads its wiring from repo **variables**, so new environments configure instead of patching YAML:

```sh
gh variable set AWS_REGION   -R <owner>/<service-repo> --body "<region>"
gh variable set ECR_REGISTRY -R <owner>/<service-repo> --body "<acct>.dkr.ecr.<region>.amazonaws.com"
gh variable set ECR_REPO     -R <owner>/<service-repo> --body "<ecr_repo_name>"
gh variable set CI_ROLE_ARN  -R <owner>/<service-repo> --body "<roles.gh_actions from platform_config>"
```

## 6. Run it

```sh
KARGO_ADMIN_PASSWORD="$(openssl rand -base64 18)" ./scripts/bootstrap.sh all
```

Then the three browser steps against the **new** names: OAuth app in the new org (callback `https://argocd.<domain>/api/dex/callback`), DNS token at the real DNS host (IP-filtered to the new `nat_egress_ip`), both into the new account's Secrets Manager (`argocd/dex-github`, `platform/cloudflare-dns`). Finish with `SETUP-GUIDE.md` §7's checklist and one real commit through the pipeline.

## Known deltas a new environment must not forget

- Permission sets: add `eks:Describe*`, `eks:List*`, `eks:AccessKubernetesApi` to any set that should see the EKS console (gotcha #20); manage them with `aws-ssoadmin` Terraform this time.
- Root can never see the clusters (gotcha #21) — humans are Identity Center users in groups from day one.
- Every rebuild re-applies the Kargo password you feed it (gotcha #14).

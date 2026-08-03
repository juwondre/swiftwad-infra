# The complete setup guide — vendor-isolated GitOps delivery platform

A from-zero, step-by-step walkthrough for building this platform, written for someone who has never seen it. Every step says **what** to run, **why** it exists, and **why it lives where it does**. Scaling guidance is inline at each layer plus a dedicated section at the end. Everything here was built, destroyed, rebuilt from script, and verified live — the gotchas are paid for.

Companion documents: `PLATFORM-SETUP.md` (terse operator reference), `scripts/bootstrap.sh` (automates phases 2–7).

---

## 0. What you are building and why

**The problem**: multiple vendor teams write and deploy applications on your AWS account. You need them to ship code fast without ever touching infrastructure, other vendors' workloads, or each other's data — and you need every change (app or infra) to be reviewable, auditable, and reversible.

**The answer in one sentence**: vendors write code; machines move it; humans approve exactly one thing.

```
 vendor repo (code only)      gitops repo (write-closed)         infra repo (invisible to vendors)
      |                             ^        ^                          |
      | merge PR                    |        |                          | PR -> Atlantis plans
      v                            |        |                          | "atlantis apply" -> applies
 GitHub Actions ──OIDC──> ECR      |        |                          v
                           |       |        |                      Terraform
                           v       |        |               (VPC, EKS, IAM, ECR, WAF, DNS glue)
                    Kargo Warehouse┘        |
                    (polls every 30s)   ArgoCD hub  ── syncs ──> dev cluster (spoke)
                           |                └────── syncs ──> staging cluster (in-cluster)
               dev Stage: auto-promote
               staging Stage: HUMAN GATE (button in Kargo UI)
```

**Why the isolation works — where each boundary is enforced:**

| Boundary | Enforced by | Not by |
|---|---|---|
| Vendors can't touch infra | Repo permissions (they can't even read the infra repo) | Trust or process docs |
| Vendor CI can only push its own image | IAM OIDC trust condition scoped to one repo, role allows one ECR repo | Runner configuration |
| Only reviewed images run | ECR-only regex in the chart schema + immutable tags | Convention |
| Only automation writes deploy config | GitOps repo write-closed; Kargo has the only deploy key | Code review vigilance |
| Vendors see only their own apps | ArgoCD AppProject + RBAC (`policy.default: ""`) and Kargo project-scoped RBAC | UI hiding |
| Random GitHub users can't log in | Dex org filter — login fails server-side for non-members | Obscurity of the URL |
| Humans approve staging/prod | Kargo Stage `sources: stages: [dev]` + the `promote` RBAC verb | Deployment freeze emails |

---

## 1. Prerequisites — check these BEFORE building anything

Tools on the machine running the bootstrap: `terraform >= 1.9`, `helm 3`, `kubectl`, `aws` CLI v2, `gh` CLI, `jq`, `openssl`, `htpasswd`, `dig`.

**1.1 — AWS vCPU quota.** Each t3.medium consumes 2 On-Demand vCPUs; the base platform needs 5 nodes (10 vCPUs) of *headroom*, not total.

```sh
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value'
# If tight, request early — approval can take a day of human review:
aws service-quotas request-service-quota-increase --service-code ec2 \
  --quota-code L-1216C47A --desired-value 32
```

*Why first*: node groups fail with `VcpuLimitExceeded` mid-provisioning otherwise, and the failure arrives 10 minutes into a 25-minute apply. We lost an hour to this.

**1.2 — GitHub billing health.** A billing-locked account refuses to start *any* Actions job, even on public repos, with an error visible only in check-run annotations:

```sh
gh api repos/<ORG>/<any-repo>/actions/runs --jq '.workflow_runs[0].conclusion'
```

**1.3 — Find out who actually serves your domain's DNS.** Do not assume Route53:

```sh
dig +short NS <yourdomain.com>
```

*Why*: our account had a Route53 zone for the domain, but the registrar delegated to Cloudflare — records written to Route53 never resolve publicly. This single check decides your external-dns provider (phase 6) and would have saved us a debugging session.

**1.4 — GitHub org, not personal account.** Dex maps org *teams* to permissions; personal accounts have no teams. Verify you're an org admin:

```sh
gh api user/memberships/orgs/<ORG> --jq '.role'   # must be "admin"
```

**1.5 — Org security settings** (the org IS part of your auth boundary once SSO gates on membership):

- Require 2FA (Settings → Authentication security). Enabling removes non-2FA members — warn people first.
- Base repository permission → **none** (default "read" lets every vendor read every org repo).
- Disallow member creation of public repositories.

---

## 2. The three repos — the security model is the repo layout

Create three repositories. This split is not organizational tidiness; it *is* the access control:

| Repo | Contains | Vendor access | Why separate |
|---|---|---|---|
| `<org>/platform-infra` | Terraform, this guide, bootstrap script, `atlantis.yaml` | **None** | Vendors who can read infra code can enumerate your attack surface; vendors who can write it own your account |
| `<org>/platform-gitops` | Helm chart template, `envs/*/`, ArgoCD + Kargo config | Read at most | The deploy state of every environment. One writer per file: Kargo owns `image.tag`, humans own everything else via PR |
| `<org>/<service>` (one per app) | Source, Dockerfile, one build workflow | **Write** (the vendor's own repo only) | The vendor's entire world. Nothing in it grants anything beyond building one image |

**Why one repo per service instead of a vendor monorepo**: the OIDC trust condition (phase 4) is per-repo. One repo = one IAM role = one ECR repo = blast radius of a fully compromised vendor CI is "they pushed an image to their own registry."

```sh
gh repo create <org>/platform-infra --private
gh repo create <org>/platform-gitops --private   # or public; contains no secrets by design
gh repo create <org>/sample-api --private
```

---

## 3. Terraform state, then core infrastructure

**3.1 — State bucket** (versioned S3; native lockfile, no DynamoDB needed on TF ≥ 1.9):

```sh
aws s3api create-bucket --bucket <org>-tf-state-<ACCOUNT_ID>
aws s3api put-bucket-versioning --bucket <org>-tf-state-<ACCOUNT_ID> \
  --versioning-configuration Status=Enabled
```

*Why versioned*: state corruption recovery. We used it. Backend config uses `use_lockfile = true` and **no hardcoded AWS profile** — laptops export `AWS_PROFILE`, in-cluster tools use IRSA. Hardcoding a profile breaks the moment Atlantis (phase 7) runs terraform in a pod.

**3.2 — Core apply.** The `terraform/` directory in this repo creates:

- **One VPC**, 2 AZs, **single NAT gateway** with a **terraform-owned EIP** (`aws_eip.nat` + `external_nat_ip_ids`).
  *Why single NAT*: ~$32/month each; non-prod doesn't need AZ-redundant egress. *Why the explicit EIP*: any credential you IP-filter to your egress (we filter the Cloudflare token) dies silently when an auto-allocated EIP rotates on rebuild.
- **One EKS cluster per environment** (`for_each` over `["dev", "staging"]`), current-generation version (check `aws eks describe-cluster-versions` — older versions bill 6× in extended support), `AL2023` AMIs, 2× t3.medium per cluster.
- ```hcl
  enable_cluster_creator_admin_permissions = false
  access_entries = { for i, arn in var.operator_principal_arns : "operator-${i}" => { ... } }
  ```
  *Why, emphatically*: creator-based admin belongs to *whoever ran terraform last*. When Atlantis takes over applies, it silently replaces the human's access entry and every laptop loses kubectl on every cluster (this locked us out twice). Declared operators make the plan identical no matter who runs it. **Day one. Not later.** Retrofitting requires state imports.
- **EBS CSI driver addon + a default `gp3` StorageClass**.
  *Why both*: EKS ships no storage provisioner, and — separately — no StorageClass is marked default on current EKS, so any PVC without an explicit class sits `Pending` forever *even with the driver healthy*. Two distinct traps.
- **ECR repo per service**: `image_tag_mutability = "IMMUTABLE"`, scan-on-push.
  *Why immutable*: a tag is a content-address. Promotion moves a *tag string* between environments; if tags were mutable, "the image that passed dev" is not provably "the image entering staging."
- **CI OIDC role per service repo** — the heart of vendor isolation:
  ```hcl
  condition {
    test     = "StringLike"
    variable = "token.actions.githubusercontent.com:sub"
    values = [
      "repo:<org>/<service>:*",
      "repo:<org>@<org-id>/<service>@<repo-id>:*",   # <-- REQUIRED, see below
    ]
  }
  ```
  **Gotcha (cost us three failed debugging rounds)**: GitHub now issues ID-pinned `sub` claims — `repo:owner@1234/repo@5678:ref:...`. A trust policy with only the plain form fails with a bare "Not authorized." Fetch the real prefix:
  ```sh
  gh api repos/<org>/<service>/actions/oidc/customization/sub --jq '.sub_claim_prefix'
  ```
  Also: if the account already has the GitHub OIDC *provider*, reference it with a `data` source. And IAM trust changes take ~30–60s to reach STS — a run dispatched instantly after apply may fail once; wait, don't debug.

```sh
export AWS_PROFILE=<profile>
terraform -chdir=terraform init && terraform -chdir=terraform apply   # ~25 min: clusters dominate
```

**Scaling this layer**: services scale by adding to a `services` map feeding ECR + OIDC roles with `for_each`. Environments scale by adding to the `environments` list — but see §10 before adding prod. Node capacity: bump `node_group_sizes` (remember the module *ignores desired_size after creation* — bump desired via `aws eks update-nodegroup-config` FIRST, then raise min in terraform, or the API rejects min > desired). Past ~10 services, replace static node groups with Karpenter.

---

## 4. Vendor CI — the narrowest possible pipe

Each service repo gets one workflow: checkout → OIDC assume role → build → push `$GITHUB_SHA` → **stop**.

```yaml
permissions:
  id-token: write     # OIDC token minting — this is the only credential that exists
  contents: read
steps:
  - uses: actions/checkout@v4
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/gh-actions-<service>
      aws-region: <region>
  - uses: aws-actions/amazon-ecr-login@v2
  - run: |
      IMAGE="<ACCOUNT_ID>.dkr.ecr.<region>.amazonaws.com/<service>:${GITHUB_SHA}"
      docker build -t "$IMAGE" . && docker push "$IMAGE"
```

*Why CI does NOT write to the gitops repo*: it used to (deploy key + tag bump). Once Kargo owns promotion, two writers to the same file fight. One writer per file, always. CI's entire privilege is now "push one image to one registry" — a fully compromised vendor workflow can do exactly that and nothing else.

*Why no `latest`, ever*: the chart's `values.schema.json` rejects it, ECR immutability would break it, and Kargo's `NewestBuild` selection doesn't need it.

**Scaling**: at >3 services, move the workflow body to an org-level **reusable workflow** so vendors call it but can't modify the credentialed steps. That plus OIDC means vendors can edit `.github/workflows/` freely without ever holding a secret.

---

## 5. ArgoCD — hub and spokes

**5.1 — Install the hub** on the most protected non-prod cluster (we use staging; a dedicated management cluster is the large-scale answer):

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f bootstrap/argocd-values.yaml --wait
```

*Why hub-spoke instead of ArgoCD-per-cluster*: one place to operate, one RBAC surface, one vendor login; spokes need zero inbound access (the hub dials them).

**5.2 — Register spokes declaratively** (SA + ClusterRoleBinding + long-lived token on the spoke; cluster `Secret` labeled `argocd.argoproj.io/secret-type: cluster` on the hub — see `scripts/bootstrap.sh` `phase_spokes`).
*Why not `argocd cluster add`*: the CLI needs a live gRPC path and an interactive login; the declarative route is reproducible, scriptable, and identical for spoke #1 and spoke #40.

**5.3 — Cross-cluster networking**: the hub must reach each spoke's API on 443. Same-VPC clusters still need an ingress rule on the spoke's cluster security group (`hub_to_dev_api` in `eks.tf`). Symptom when missing: apps stuck `Unknown`, `dial tcp ... i/o timeout`.

**5.4 — App-of-apps**: apply exactly one thing by hand, ever:

```sh
kubectl apply -f argocd/root-app.yaml
```

Everything else — AppProjects, Applications, platform components — syncs from git. *Why*: the cluster's contents are now a pure function of the repo. Rebuild = reapply one file.

**Sync-ordering rules we learned the hard way** (encoded in the repo):
- The `AppProject` must sync at the **most negative wave** (`-3`); Applications referencing it come later. A project at default wave 0 behind failing wave −1 resources = deadlock.
- Any CR whose CRD is installed *by the same sync* (our `ClusterSecretStore`/`ExternalSecret` before external-secrets exists) needs `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` — ArgoCD dry-run-validates everything before applying anything, so one unknown kind blocks the entire operation.

**5.5 — The chart template** (`charts/app-template` in the gitops repo): every service deploys through one chart; a service is a *values file*, not manifests. Conformance is enforced by the chart, not by review: `values.schema.json` rejects non-ECR images, `latest`, ports < 1025, missing probes/resources — and the securityContext (non-root, read-only rootfs, no capabilities) is **hardcoded in the template, not exposed in values**. A vendor cannot weaken what they cannot set.

**Scaling**: at ~10+ services, replace hand-written Applications with an **ApplicationSet** using a git directory generator over `envs/<env>/*` — onboarding a service becomes "add a values file." At 100s of apps, shard the application controller (`ARGOCD_CONTROLLER_REPLICAS` + sharding by cluster) and raise repo-server replicas. At many clusters, spoke registration is already a loop in the bootstrap script.

---

## 6. Kargo — promotion as a first-class system

**6.1 — Install** (cert-manager first — Kargo's webhooks need certs):

```sh
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager \
  --create-namespace --set crds.enabled=true --wait

helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo -n kargo \
  --create-namespace -f bootstrap/kargo-values.yaml \
  --set api.adminAccount.passwordHash="$(htpasswd -bnBC 10 '' "$KARGO_PW" | tr -d ':\n')" \
  --set api.adminAccount.tokenSigningKey="$(openssl rand -base64 32 | tr -d '=+/')" --wait
```

*Why the split*: non-secret values live in git (`bootstrap/kargo-values.yaml`); only secrets are injected at install. **Rebuild warning**: the script re-applies whatever password you feed it — feed it a fresh secret, or your careful rotation silently reverts (ours did).

**6.2 — Freight discovery**: the controller polls ECR via **IRSA** (`kargo.tf` role: `DescribeImages`, `BatchGetImage`, `GetDownloadUrlForLayer` on your repos + `GetAuthorizationToken`).

```yaml
spec:
  interval: 30s                      # vendor pushes surface in dev ~1 CI-build after merge
  subscriptions:
    - image:
        repoURL: <ACCOUNT_ID>.dkr.ecr.<region>.amazonaws.com/<service>
        imageSelectionStrategy: NewestBuild   # tags are git SHAs — SemVer finds NOTHING
```

*Why 30s polling instead of webhooks*: ECR emits no webhooks; the push-based route is EventBridge → public endpoint → Kargo's external webhook server — real infrastructure for marginal gain. At 30s × a handful of repos, `DescribeImages` cost is noise. Revisit at ~50 repos.

**6.3 — Project and stages** (`kargo/` in the gitops repo):
- **Name the Kargo project `<service>-delivery`, not `<service>`** — a Project owns a namespace named after itself *on the hub cluster*, and your app may already occupy that namespace there. This collision cost us a broken first apply.
- Dev stage: `sources: { direct: true }` + `autoPromotionEnabled: true` in `ProjectConfig`.
- Staging stage: `sources: { stages: [dev] }` — **structurally** only freight that passed dev is eligible. This is the promotion policy as data, not documentation.
- Promotion steps: `git-clone` → `yaml-update` → `git-commit` → `git-push` → `argocd-update`. Kargo pushes with its **own write deploy key** (secret labeled `kargo.akuity.io/cred-type: git` in the project namespace, `repoURL` matching the clone URL exactly). Annotate each ArgoCD Application `kargo.akuity.io/authorized-stage: <project>:<stage>` or `argocd-update` refuses.

*Why promotion-by-git-commit*: the gitops log IS the audit trail — Kargo's commits interleaved with human PRs, `git revert` is the rollback.

**6.4 — The `promote` verb**: creating a `Promotion` requires RBAC verb `promote` on the Stage, and **EKS access-policy admin does not satisfy custom verbs** — bind an explicit Role. This verb is precisely "release manager": grant it to your engineering team, never to vendors.

**Scaling**: services = warehouse + stages + values files each (template them). A prod environment = one more cluster (spoke), one more stage with `sources: {stages: [staging]}`, same gate mechanics — the system is N-stage by construction. Verification steps (smoke tests between stages) slot into `spec.verification` when promotion volume justifies them.

---

## 7. Atlantis — infra changes as PRs

```sh
helm repo add runatlantis https://runatlantis.github.io/helm-charts
helm upgrade --install atlantis runatlantis/atlantis -n atlantis --create-namespace \
  --set orgAllowlist="github.com/<org>/platform-infra" \
  --set github.user=<bot-user> --set github.token="$GH_TOKEN" \
  --set github.secret="$WEBHOOK_SECRET" \
  --set service.type=LoadBalancer \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<atlantis-role-arn>" \
  --set volumeClaim.storageClassName=gp3 --wait
# then: webhook on the infra repo -> http(s)://<atlantis-host>/events
# events: push, pull_request, pull_request_review, issue_comment
```

Flow: PR touching `*.tf` → Atlantis comments the plan → review → comment `atlantis apply` → applied under a state lock → merge. Nobody runs `terraform apply` from a laptop for routine changes again.

*Why Atlantis over Actions-based terraform*: PR-comment applies with automatic state locking, per-PR plan caching, and re-plans on every push — drift-proof feedback until merge. *Why the IRSA role is admin (POC)*: this terraform manages IAM/VPC/EKS; scope with a permissions boundary in production.

**Three operational rules, each paid for in incident time:**
1. **Atlantis cannot replace the NAT gateway it egresses through.** Destroy-then-create kills its own AWS/S3/GitHub connectivity mid-apply — it can't even report the failure. Run VPC-egress surgery from a laptop (this is what break-glass credentials are for), or add VPC endpoints for S3/STS/EC2 so terraform survives NAT loss.
2. **Never `force-unlock` a lock whose owner may still be alive.** Our stalled Atlantis apply resumed when egress returned and overwrote state written in the interim; repair required `terraform import` of orphaned resources. Kill the pod first, or wait.
3. **`apply_requirements: [approved, mergeable]`** in `atlantis.yaml` the moment more than one person operates this.

**Production upgrades**: GitHub App auth instead of a personal token (finer permissions, no user coupling); ingress + TLS instead of a bare LoadBalancer; webhook restricted to GitHub's IP ranges.

---

## 8. Exposure and SSO — one identity system for everything

**8.1 — Platform controllers as ArgoCD Applications** (`argocd/apps/platform/` in the gitops repo): aws-load-balancer-controller, external-dns, external-secrets — each a pinned helm chart with an IRSA annotation, under a `platform` AppProject.
*Why in ArgoCD rather than the bootstrap script*: the script bootstraps; ArgoCD *operates*. Version bumps become PRs with diffs.

**8.2 — DNS**: external-dns watches ingresses and publishes records **to whoever actually serves your zone** (see §1.3). Cloudflare provider needs a zone-scoped, DNS-edit-only API token, delivered via ExternalSecret, **IP-filtered to the permanent NAT EIP** — a stolen token is then useless off your network.

**8.3 — ArgoCD behind an ALB**:

```yaml
server:
  replicas: 2
  ingress:
    enabled: true
    ingressClassName: alb
    hostname: argocd.<domain>
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/certificate-arn: <wildcard-acm-cert-arn>
      alb.ingress.kubernetes.io/wafv2-acl-arn: <waf-acl-arn>
```

TLS terminates at the ALB (`server.insecure: true` behind it is the standard pattern, not a compromise). WAF carries AWS managed rules + a per-IP rate limit. *Why public-with-strong-auth instead of VPN for vendors*: you don't manage vendor laptops; a VPN adds support burden without adding a boundary SSO doesn't already provide.

**8.4 — GitHub SSO via Dex** (bundled with ArgoCD):

```yaml
dex.config: |
  connectors:
    - type: github
      config:
        clientID: $argocd-dex-github:clientID        # delivered by ExternalSecret,
        clientSecret: $argocd-dex-github:clientSecret # label part-of: argocd required
        orgs: [{name: <org>}]        # <-- THE GATE: non-members fail at Dex, server-side
        teamNameField: slug
rbac:
  policy.csv: |
    p, role:vendor-readonly, applications, get, <vendor-project>/*, allow
    p, role:vendor-readonly, logs, get, <vendor-project>/*, allow
    g, <org>:<vendor-team>, role:vendor-readonly
    g, <org>:engineering, role:release-manager
  policy.default: ""                 # <-- authenticated-but-unmapped = nothing
  scopes: "[groups]"
```

The OAuth app is **org-owned** (survives personnel changes); callback `https://argocd.<domain>/api/dex/callback`; credentials go to Secrets Manager and flow through ESO — never into git, state, or a chat transcript. Remove any local test accounts once SSO is verified; `admin` stays as documented break-glass.

**8.5 — Kargo on the same SSO** (`kargo.<domain>`): same ALB pattern (backend re-encrypted to kargo-api's own TLS), and Kargo points at **ArgoCD's Dex as its OIDC issuer** with a PKCE public static client — one OAuth app, one org gate, both UIs:

```yaml
# argocd dex.config gains:
staticClients:
  - id: kargo
    name: Kargo
    public: true
    redirectURIs: [https://kargo.<domain>/login]
```

**Two gotchas that WILL hit you here:**
- **CORS**: Kargo's UI fetches Dex's discovery/token endpoints cross-origin *from the browser*. ArgoCD's embedded Dex discards `web.allowedOrigins` (verified in its generated config), so inject the header at the ArgoCD ALB instead:
  `alb.ingress.kubernetes.io/listener-attributes.HTTPS-443: routing.http.response.access_control_allow_origin.header_value=https://kargo.<domain>`
- **Kargo RBAC is two-layer.** Per-project SAs with `rbac.kargo.akuity.io/claim.groups: <org>:<team>` annotations grant *inside* a project — but the UI's landing page lists Projects, a **cluster-scoped** verb. Without the global layer, every SSO login greets users with "list is not permitted." Register a global namespace (`api.oidc.globalServiceAccounts.namespaces: [kargo-global]`) holding claim-annotated SAs: engineering → cluster `kargo-admin`; vendors → a minimal ClusterRole with only `get/list/watch` on `projects`, so they see project *names* but enter only their own.

---

## 9. Onboarding a new vendor service — the repeatable recipe

Once the platform exists, each new service is four small changes and zero new concepts:

1. **GitHub**: create `<org>/<service>` (vendor gets write) + a `<vendor>` team if it's a new vendor.
2. **Infra PR** (through Atlantis): ECR repo + OIDC role — copy the `sample_app` pattern, remember *both* sub-claim forms.
3. **Gitops PR**: `envs/dev|staging/<service>.yaml` values files (start from `charts/app-template/example-values.yaml`), ArgoCD Applications (or nothing, if you've moved to ApplicationSets), `kargo/<service>/` warehouse + stages, three RBAC lines if it's a new vendor team.
4. **Vendor**: drops in the standard workflow file, meets the conformance doc (probes, SIGTERM, non-root, env-var config, no local state — enforced by the chart schema anyway), merges to main — and watches their change reach dev in ~3 minutes at `kargo.<domain>`.

Offboarding a vendor = remove them from the GitHub team. Their SSO sessions stop resolving to anything.

---

## 10. Scaling scenarios — what changes when things grow

**More services (1 → 10 → 100)**
- 1–5: exactly this guide.
- ~10: ApplicationSets (directory generator over `envs/`); reusable CI workflow; a `services` map in terraform generating ECR+OIDC per entry; Karpenter replaces static node groups.
- ~50–100: shard the ArgoCD application controller; raise repo-server replicas; revisit Kargo polling (batch intervals, or invest in the EventBridge webhook path); per-namespace ResourceQuotas become mandatory, not optional.

**More vendors**
- Everything is already per-vendor: team, AppProject, RBAC lines, Kargo project. Generate the boilerplate (a small script or terraform `templatefile`) once you pass ~5 vendors so nobody hand-edits RBAC.
- Vendors never share namespaces, AppProjects, or ECR repos. NetworkPolicies between vendor namespaces become mandatory at multi-vendor scale.

**More environments (adding prod)**
- Mechanically: one more cluster (spoke), one more Kargo stage gated on staging, values overlay, done — the system is N-stage by design.
- **But**: prod belongs in a **separate AWS account**. The account boundary is the strongest isolation primitive AWS has; the mature shape is an AWS Organization with dev/staging/prod accounts plus a shared-services account (ECR, CI roles, state). Consolidate account *sprawl*, never environment *boundaries*. Hub-spoke ArgoCD spans accounts fine (spoke registration is identical; networking becomes VPC peering/TGW + the same SG rule pattern).

**More regions**
- Only add regions for latency or compliance reasons — every region is a full cluster + NAT + ELB cost line. The consolidation you did *into* this platform was probably the right direction.
- If genuinely needed: clusters are already `for_each`; spokes register in a loop; ECR replication rules handle image locality; keep ONE hub.

**More people**
- `apply_requirements: [approved, mergeable]` on Atlantis; CODEOWNERS on `envs/staging/` and `envs/prod/` in the gitops repo; the Kargo `promote` verb is your release-manager grant — bind it per stage, so "can promote to staging" and "can promote to prod" are different groups.

**More traffic**
- The chart already carries HPA + PDB knobs per service. Cluster capacity → Karpenter.
- ELB sprawl: each ingress currently provisions its own ALB (~$18/month each). Add `alb.ingress.kubernetes.io/group.name: platform` to share one ALB across ArgoCD, Kargo, and future UIs — first cost cleanup worth doing.

**Higher security bar**
- Cosign image signing in the reusable workflow + a Kyverno admission policy (only signed images from your ECR) closes the "someone hand-applied a manifest" hole cluster-side.
- VPC endpoints (S3, ECR, STS, EC2) remove the NAT from the critical path — cheaper at scale AND it defuses the Atlantis-NAT incident class entirely.
- Permissions boundary on the Atlantis role; scope it from admin down to what the plans actually touch.

---

## 11. Day-2 operations

**Verify end-to-end after any major change** (the same checklist the bootstrap `verify` phase prints): CI green → image in ECR → freight within a minute → dev auto-promoted, gitops log shows a Kargo commit → staging unchanged until a human promotes → both UIs reachable over SSO → vendor sees only their own world.

**Teardown / park it** (validated: rebuild is ~45 min from the script):

```sh
helm -n atlantis uninstall atlantis        # kills its ELB — otherwise VPC deletion hangs
aws ecr batch-delete-image --repository-name <service> \
  --image-ids "$(aws ecr list-images --repository-name <service> --query 'imageIds[*]' --output json)"
# delete GitHub webhook + kargo deploy key (they point at infrastructure about to die)
terraform -chdir=terraform destroy
```

**Break-glass inventory** (document it, test it annually): one IAM operator user in `operator_principal_arns` with kubectl on every cluster; ArgoCD `admin` (initial secret in-cluster); Kargo admin password (secret manager / credentials file — and re-set on every rebuild, see §6.1).

**Cost picture (POC sizing, us-east-1)**: 2 control planes ~$146, 5× t3.medium ~$150, NAT ~$35, 3 ELBs ~$54, WAF ~$10 → **~$395/month**. First savings: ALB `group.name` sharing (−$36), then Karpenter with spot for non-prod nodes.

---

## 12. The gotcha index — every trap this guide already defused

Each of these cost real debugging time once, so you never pay for it again:

1. vCPU quota exhaustion mid-node-group-creation (§1.1)
2. GitHub billing lock silently refusing Actions jobs (§1.2)
3. Route53 zone that isn't actually in the public delegation path (§1.3)
4. ID-pinned OIDC `sub` claims failing plain-form trust policies (§3.2)
5. IAM trust-policy propagation racing the first CI run (§3.2)
6. EKS module ignores `desired_size` after creation — bump via API before raising min (§3, scaling)
7. Cluster-creator admin flip-flop locking laptops out — operators in code, day one (§3.2)
8. No storage provisioner AND no default StorageClass on EKS — two separate traps (§3.2)
9. ArgoCD sync dry-run blocking on CRDs installed by the same sync (§5.4)
10. AppProject sync-wave ordering deadlock (§5.4)
11. Kargo project namespace colliding with the app's namespace on the hub (§6.3)
12. `NewestBuild` vs SemVer for SHA tags (§6.2)
13. The Kargo `promote` verb — EKS access policies don't cover custom verbs (§6.4)
14. Rebuild silently reverting rotated passwords fed to the bootstrap (§6.1)
15. Atlantis destroying the NAT it breathes through (§7)
16. Force-unlocking a live lock → zombie apply overwrites state (§7)
17. ArgoCD's Dex dropping `web.allowedOrigins` — CORS via ALB listener attributes (§8.5)
18. Kargo's two-layer RBAC — "list is not permitted" without global service accounts (§8.5)
19. Local DNS negative caching after querying a name before its record exists — verify via `dig @1.1.1.1`, not the browser (§8.2)
20. The EKS console's Resources view needs BOTH layers for the signed-in identity: IAM actions (`eks:Describe*`, `eks:List*`, `eks:AccessKubernetesApi`) on the permission set AND a cluster access entry — either alone still shows Unauthorized
21. The account **root user cannot be granted cluster access at all** (access entries reject it, by AWS design) — humans use Identity Center users in groups; root stays in the safe
22. SSO role ARNs in access entries need the **full pathed ARN** (`role/aws-reserved/sso.amazonaws.com/…`) — the opposite of the legacy aws-auth ConfigMap, which wanted paths stripped. And the role-name hash changes if the permission set is recreated
23. IAM users can't hold Identity Center permission sets — "I granted the new IAM user the engineering role" silently grants nothing. Humans = Identity Center; machines = IAM roles with scoped trust; nobody = long-lived IAM users
24. Manage permission sets with the `aws-ssoadmin` Terraform resources in the real project — ours was edited via CLI and is the one access-relevant config not yet in code

# Onboarding a vendor service

The platform-team checklist for putting a new service on the platform. Roughly an hour of work spread across two PRs, plus whatever the vendor needs to meet conformance.

## Part 1 — Assess before you commit (30 minutes with the vendor)

Score the service against the conformance doc. **Migrate the cleanest services first**: the first two or three through the pipeline are really about proving the pipeline, so don't spend them on the hard cases.

| Question | Blocker? | If no |
|---|---|---|
| Containerised, builds from a Dockerfile? | **Yes** | Vendor work before onboarding |
| Runs as non-root? | **Yes** | Chart enforces it — vendor must fix the image |
| Config entirely from env vars? | **Yes** | Baked-in config must come out |
| Liveness + readiness endpoints? | **Yes** | Deploys can't roll safely without them |
| Handles SIGTERM? | No, but | Every deploy and node rotation sends one — expect restarts |
| No local disk state? | **Yes** | Needs S3/RDS or a documented StatefulSet exception |
| Logs to stdout? | No, but | Otherwise logs never reach CloudWatch |
| Metrics on `/metrics`? | No | Dashboards stay partly empty until they add it |
| Traces via OTel SDK? | No | Platform injects the endpoint whenever they're ready |

**Also capture**: expected CPU/memory, replica count, secrets required (names only), external dependencies (databases, third-party APIs), and any egress the service needs.

Rank the wave: everything green → wave 1. One or two ambers → wave 2. Any red → vendor work first, and give them the conformance doc plus a target date.

## Part 2 — Platform-team setup (about an hour)

**GitHub**
1. Create the service repo, give the vendor's team write access to *that repo only*.
2. If it's a new vendor, create their team: `gh api orgs/<org>/teams -X POST -f name='vendor-<name>' -f privacy='closed'`.

**Infra PR** (Atlantis plans, you apply, then merge)
3. ECR repository for the service.
4. CI OIDC role scoped to that one repo and that one ECR repo — remember **both** sub-claim forms (plain and ID-pinned; get the pinned prefix from `gh api repos/<org>/<repo>/actions/oidc/customization/sub`).

**GitOps PR**
5. `envs/dev/<service>.yaml` and `envs/staging/<service>.yaml` from `charts/app-template/example-values.yaml` — set the image repository, resources, env vars, `metrics.enabled`/`tracing.enabled` if they're instrumented.
6. ArgoCD Applications for dev and staging, each carrying `kargo.akuity.io/authorized-stage`.
7. Kargo `Project` (**named `<service>-delivery`, never `<service>`**), `Warehouse`, and dev/staging `Stage`s.
8. New vendor only: ArgoCD AppProject + three RBAC lines; Kargo claim-mapped ServiceAccounts for their team.
9. Secrets they need: create in Secrets Manager under `<service>/*`, add `externalSecrets` entries to their values files. **Never** the values themselves in git.

**Service-plane exposure (platform team — NOT the vendor)**

The vendor never touches DNS, certificates, load balancers, or their own exposure. Those live in the gitops repo, which they cannot write to. Per service that needs to serve external traffic:

9a. Decide exposure and set it in the values file: `ingress: {enabled: true, public: true, host: <their real hostname>}`. Default is `public: false` (internal ALB) — make public a deliberate choice.
9b. TLS: request an ACM certificate covering that hostname (or omit `certificateArn` and let the controller auto-discover a matching one). If the domain belongs to someone else, they add one validation record — once.
9c. DNS: whoever owns that domain points a CNAME at the shared vendor-public ALB. Apex domains need ALIAS/flattening rather than CNAME.

No new load balancer, no infra ticket: services join the shared ingress group.

**Vendor side — and this is their entire surface**
10. They add the standard build workflow (copy it — it reads repo variables, no edits).
11. You set the four repo variables: `AWS_REGION`, `ECR_REGISTRY`, `ECR_REPO`, `CI_ROLE_ARN`.
12. They merge to `main`.

## Part 3 — Verify the first delivery (10 minutes)

Watch it together — this is also their training:

1. CI goes green; image appears in ECR tagged with the commit SHA.
2. Freight appears in Kargo within ~30 seconds of the push.
3. Dev auto-promotes; the gitops repo shows a commit authored by Kargo; the app goes Healthy.
4. You promote to staging with the button; it deploys the *same* immutable image.
5. Show them their dashboards, their read-only view, and where logs live.

Tell them plainly what they can and can't do: **push code, watch everything, change nothing about infrastructure, promote nothing.** Alerts are the platform team's — they get dashboards and their service's health.

## Part 4 — Offboarding (2 minutes, whenever it happens)

1. Remove the vendor's team from the GitHub repo and the org team → all UI access ends with their session.
2. Archive the service repo.
3. Remove their values files, Applications, and Kargo project in a gitops PR — ArgoCD prunes the workloads.
4. Delete the ECR repo and the CI OIDC role in an infra PR.

No credential hunt, because there were never any credentials to hunt.

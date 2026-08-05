# POC → production roadmap

The platform is functionally complete and twice-validated: vendors are isolated, delivery is automated dev→staging with a human gate, infrastructure changes go through reviewed PRs, and the whole environment rebuilds from automation in ~45 minutes. This document is the gap between that and something that carries production traffic for vendors you don't employ.

Ordered by dependency, then by value-per-effort. Effort figures assume one engineer familiar with the platform.

---

## Phase 1 — Observability (2–3 weeks) · **start here**

The single largest gap: today the platform can tell you a deployment *happened*, not whether it's *healthy*. Independent of every other phase, so it starts immediately; everything downstream benefits from having it first (you want prod migrations watched by instruments that already work).

| Layer | Choice | Rationale |
|---|---|---|
| Metrics | AWS Managed Prometheus + `kube-prometheus-stack` (agent mode, remote-write) | No Prometheus HA/storage to operate; clusters stay stateless and disposable — which the rebuild story depends on |
| Dashboards | Amazon Managed Grafana, SSO via Identity Center | Per-team folders; vendors get read-only dashboards scoped to their namespace |
| Logs | Fluent Bit → CloudWatch Logs (Loki if you want query parity in Grafana) | Replaces "vendors tail logs through ArgoCD" with a real log surface and per-team access |
| Traces | ADOT collector, OTLP endpoint injected by the app chart → X-Ray (or Tempo) | Vendors instrument with vanilla OTel SDKs; the platform supplies the endpoint |
| Alerting | Alertmanager → PagerDuty/Slack, routed by namespace label | A vendor's alerts reach the vendor, not your on-call |
| Platform SLOs | Deployment frequency, promotion lead time, sync failure rate, freight age | The platform measuring itself — this is what keeps the business case renewable |

Delivery: every component ships as an ArgoCD Application in the `platform` project (same pattern as the ALB controller), IRSA roles via Terraform. Conformance doc gains two enforceable lines: expose `/metrics`, propagate trace headers.

**Done when**: a vendor can answer "is my service healthy?" without asking you, and you can answer "is the platform healthy?" without kubectl.

## Phase 2 — Account topology + prod environment (2–3 weeks)

- **AWS Organization with an account per environment** (dev / staging / prod) plus shared-services (ECR, CI roles, state). The account boundary is the strongest isolation AWS offers; consolidate account *sprawl*, never environment *boundaries*.
- Cross-account spoke registration for the prod cluster (mechanically identical to today's dev spoke; networking via TGW/peering + the same SG rule pattern).
- **Prod Kargo stage**: `sources: {stages: [staging]}`, a `prod-approvers` GitHub team, and a promote Role scoped `resourceNames: ["prod"]` — "can ship to staging" and "can ship to prod" become different grants.
- ECR replication to the prod account (or keep one registry in shared-services and grant pull).

**Done when**: a change reaches prod only by passing dev, then staging, then a named approver in a team distinct from staging's.

## Phase 3 — Supply chain + security hardening (1–2 weeks)

- **Cosign signing in CI + Kyverno admission**: cluster runs only signed images from your ECR. Closes the "someone hand-applied a manifest" class entirely.
- **VPC endpoints** (S3, ECR, STS, EC2): cheaper at scale, removes NAT from the critical path, and structurally kills the "Atlantis replaces the NAT it breathes through" incident class.
- **Atlantis as a GitHub App** (not a user PAT) with a permissions boundary on its IAM role; webhook restricted to GitHub's published CIDRs; `apply_requirements: [approved, mergeable]`.
- **Per-vendor NetworkPolicies and ResourceQuotas** — mandatory once more than one vendor shares a cluster.
- **Identity Center permission sets in Terraform** (`aws-ssoadmin` resources) — the last access-relevant config still managed by hand.

## Phase 4 — Vendor-facing exposure (1 week)

Only if not already done: domain + wildcard cert, ingresses on, GitHub SSO live in both UIs, org security prerequisites enforced (2FA required, base repo permission `none`, no member public repos). Internal ALBs + VPN if vendor access should stay off the public internet — noting Atlantis must remain publicly reachable for GitHub webhooks.

**Done when**: vendors log in with their own GitHub identity, see only their project, and every promotion is attributed to a named human.

## Phase 5 — Scale and resilience (ongoing)

- **Karpenter** replaces static node groups (~10+ services or bursty workloads).
- **ApplicationSets** (directory generator over `envs/`) — onboarding a service becomes "add a values file".
- **Multi-AZ NAT** for prod; PDBs already ship in the chart.
- **Chart-per-app** for services whose shape outgrows the shared template (StatefulSets, CronJobs, sidecars): chart lives in the vendor's repo, values stay in the gitops repo — vendor owns structure, platform owns every environment-specific value.
- **EKS upgrade cadence** — a version reaches end of standard support roughly annually; extended support bills ~6×. One cluster at a time, dev first, `cluster_version` in tfvars.
- **Backup/restore** for ArgoCD and Kargo state (both reconstruct from git, but promotion history and RBAC bindings are worth snapshotting).

## Phase 6 — Migration of real services (parallel with 2–5)

1. Rank candidate services by the conformance checklist; migrate cleanest first.
2. Two or three services end-to-end as a first wave; calibrate vendor onboarding from real friction.
3. Remaining services in waves; decommission EC2 per service as each cutover completes.
4. Consolidate regions once deployment is uniform.

---

## Sequencing summary

```
Phase 1 (observability) ──┬── Phase 3 (security)  ── Phase 5 (scale, ongoing)
                          └── Phase 2 (accounts, prod) ── Phase 4 (exposure) ── Phase 6 (migration waves)
```

Phase 1 is independent — start now. Phase 2 gates prod traffic. Phase 4 gates vendor self-service. Phase 6 runs alongside 2–5 as capacity allows.

## Cost trajectory

POC sizing (2 environments, no observability): ~$395/month. Expect roughly **$900–1,400/month** at production shape — three environments in separate accounts, AMP/Grafana/log retention, multi-AZ NAT in prod. Levers already identified: shared ALB via ingress `group.name`, spot capacity for non-prod nodes, log retention tiering, and parking non-prod environments out of hours (the ~45-minute validated rebuild makes this genuinely viable).

---

## Phase 1 delivery notes (what shipped)

**Backends (Terraform, behind `enable_observability`)**: AMP workspace, workloads log group with configurable retention, IRSA roles for the Prometheus agent and Fluent Bit (per cluster) and for Grafana (hub).

**Collectors and UI (ArgoCD Applications in the `platform` project)**: kube-prometheus-stack in agent mode remote-writing to AMP; Fluent Bit to CloudWatch; Grafana with GitHub SSO, AMP + CloudWatch datasources, and dashboards provisioned from ConfigMaps in the gitops repo.

**Dashboards**: `Platform — delivery health` (sync/health counts, deployment frequency, reconciliation p95, application inventory) and `Service overview` (namespace-templated: pods ready, restarts, CPU/memory against limits, and RED panels that populate once a service is instrumented per conformance §9).

**Bootstrap**: an `observability` phase seeds Grafana's OAuth placeholder, prints the AMP endpoints, and waits for the stack; `all` runs it automatically when the backends exist.

**Grafana role mapping** (GitHub org teams → Grafana roles): `platform` → Admin, `engineering` → Editor, every other org member → Viewer.

**Known limitation — per-team folder isolation.** Grafana OSS maps identities to *roles*, not to *teams*, without Enterprise team-sync. Today every authenticated org member can see both folders; the Service dashboard's namespace variable organises by service rather than restricting by it. Options when strict isolation is required: (a) Amazon Managed Grafana with Identity Center groups and folder permissions (per-user cost, folder permissions via API), (b) Grafana Enterprise team sync, or (c) one Grafana per vendor for the extreme case. Recommendation: accept the current state for internal teams, and revisit before vendors get Grafana access — vendor log access via ArgoCD and per-namespace CloudWatch is already isolated.

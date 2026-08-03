# Vendor Delivery Platform — Architecture & Justification

**Audience**: project leadership and internal customers (team leads whose services and vendors run on this platform).
**Status**: proof of concept complete — every claim in this document was demonstrated live, not projected. A destroy-and-rebuild of the entire platform from automation was performed as validation.
**Companion documents** (technical): `SETUP-GUIDE.md`, `PLATFORM-SETUP.md`, `RBAC-DELEGATION.md`.

---

## 1. Executive summary

Today, vendor-built applications run on EC2 instances spread across several AWS regions, deployed by the vendors themselves with direct access to our cloud environment. This creates three standing problems: **vendors can touch infrastructure they shouldn't**, **nobody can answer "what is running where, and who put it there" from records**, and **the infra team spends real time on "is my change deployed yet?" traffic**.

The platform replaces that with a simple contract: **vendors write code; automated machinery builds, tests-gates, and deploys it; exactly one human decision — the promotion approval — sits between a vendor's code and each protected environment.** Vendors lose all infrastructure access and gain something they never had: a self-service window showing exactly where their change is, in real time.

**Proven results from the POC:**

| Measure | Result |
|---|---|
| Vendor change merged → running in dev | **under 4 minutes, zero human involvement** |
| Dev → staging | **one authenticated click**, recorded against the approver's identity |
| Vendor infrastructure access | **zero** — vendors cannot read, let alone change, any infrastructure |
| Vendor onboarding | one repository + one team + a small reviewed config change (~1 hour) |
| Vendor offboarding | remove from one GitHub team — all access ends immediately |
| Full platform rebuild from nothing (disaster recovery) | **~45 minutes**, from a validated script |
| Running cost (POC sizing: 2 environments, full tooling) | **~$395/month**, with identified reductions |

---

## 2. The problem, in business terms

The current model grew organically: each vendor received enough AWS access to deploy their own application onto EC2. The consequences compound as vendors and services multiply:

1. **Unbounded blast radius.** A vendor credential — phished, leaked, or misused — is an infrastructure credential. Any vendor incident is potentially *our* incident, across everything their access touches.
2. **No authoritative record.** Deployments happen from vendor laptops and ad-hoc scripts. Questions an auditor (or an incident review) will ask — *what version is in production, who deployed it, who approved it* — are answered by asking people, not by consulting records.
3. **Operational drag on our team.** Every vendor deployment question, access request, and "can you check if it went out" lands on internal staff. This is invisible, recurring cost.
4. **Region sprawl without a driver.** Workloads run in multiple regions for historical rather than regulatory reasons — multiplying baseline cost and operational surface.
5. **Offboarding risk.** Removing a vendor today means hunting down credentials, keys, and access grants across systems. Anything missed persists silently.

None of these are hypothetical failure modes; they are standing conditions that grow linearly (or worse) with each vendor added.

---

## 3. The target architecture, at altitude

```
 VENDORS                    THE MACHINERY                        OUR TEAM
 ────────                   ─────────────                        ─────────
 write code ──► CI builds ──► registry ──► watcher detects ──► auto-deploys to DEV
 (own repo         (2-3 min)   (immutable,     (≤30 sec)             │
  only)                         scan-on-push)                        ▼
                                                            STAGING/PROD wait for
 watch progress ◄───── self-service dashboards ─────► ONE approval click
 (read-only)           (login with company-managed          (identity recorded)
                        GitHub identity)
                                                     infrastructure changes:
                                                     reviewed pull requests only,
                                                     applied by automation
```

Five building blocks, each with one job:

| Component | Job | Why this one |
|---|---|---|
| **EKS (Kubernetes)** | Runs the applications | Managed control plane; per-team isolation, quotas, and network policy are native primitives rather than bolted on |
| **GitHub + OIDC CI** | Builds vendor code into sealed, scannable images | Vendors already live here; build credentials are short-lived and scoped so a fully compromised vendor pipeline can only push its own image |
| **ArgoCD** | Continuously makes the clusters match the declared configuration | The industry-standard GitOps engine; drift is corrected automatically, and "what is deployed" is always answerable from git |
| **Kargo** | Moves versions dev → staging (→ prod) with gates | Purpose-built promotion: new builds flow to dev hands-free; protected environments structurally accept only versions that passed the previous one |
| **Atlantis + Terraform** | All infrastructure changes as reviewed pull requests | Nobody — including our own team — changes infrastructure by hand; every change has a reviewer, a plan, and an audit trail |

**The design principle throughout**: every boundary is *structural*, not procedural. Vendors don't refrain from touching infrastructure because policy says so — they hold no credential that could. Staging doesn't receive untested builds because people are careful — the promotion system has no path that skips dev.

---

## 4. Business justification

**4.1 — Risk reduction is the headline.** The vendor attack surface collapses from "our AWS environment" to "one code repository and one image registry slot." Concretely: the worst outcome of a fully compromised vendor CI pipeline was demonstrated to be *pushing an image to that vendor's own registry* — which still cannot reach any environment without passing the platform's gates. For internal customers, this means one vendor's incident cannot become your service's incident.

**4.2 — Auditability by construction.** Every deployment to every environment is a git commit; every promotion approval is recorded against a named individual's company identity (demonstrated: the POC's staging approval is attributed to the approver's email, automatically). When compliance or an incident review asks "what/when/who/who-approved," the answer is a git log, not an interview. This converts audit preparation from a project into a query.

**4.3 — Vendor lifecycle becomes cheap and safe.** Onboarding: about an hour of reviewed configuration. Offboarding: removal from one team — no credential hunt, no residue, effective immediately. For an organization that expects vendor turnover, this is the difference between vendor changes being routine and being risk events.

**4.4 — Internal staff time returns.** The "is it deployed yet" category of interruption ends: vendors watch their own changes move in a dashboard within minutes of merging. Deployment support tickets, access requests, and manual deploy assistance are replaced by self-service with guardrails.

**4.5 — Cost becomes visible and controllable.** Today's per-region EC2 sprawl is replaced by right-sized clusters with a single monthly figure (~$395 at POC sizing) and identified levers (consolidating load balancers, spot capacity for non-production). Consolidating regions — now possible because deployment is uniform — removes duplicate baseline cost. The platform can also be fully parked (destroyed) and rebuilt in ~45 minutes, which was tested, not estimated: non-production environments need not run nights and weekends if we choose.

**4.6 — The exit costs are honest.** Every component is open-source and industry-standard (Kubernetes, Terraform, ArgoCD are the de-facto defaults of this domain). There is no vendor lock beyond AWS itself, which we already carry. Skills investment transfers; hiring for this stack is easier than hiring for the bespoke status quo.

---

## 5. Technical justification (for the technically inclined reader)

- **Why Kubernetes/EKS over the EC2 status quo**: isolation (namespaces, quotas, network policies), self-healing, uniform deployment, and per-service scaling are platform features rather than per-vendor scripts. Vendor applications were found to be largely containerized already; the migration cost is pipeline-shaped, not rewrite-shaped.
- **Why GitOps (ArgoCD) over push-based deployment**: the cluster state is a pure function of a reviewed repository. Drift self-corrects; rollback is `git revert`; disaster recovery is "reapply the repo" — which the rebuild validation exercised end to end.
- **Why a dedicated promotion system (Kargo) over CI scripts**: promotion rules become data ("staging accepts only what passed dev"), not conventions in pipeline code. Approval rights are per-environment permissions with automatic attribution — precisely the control a prod gate needs.
- **Why Atlantis for infrastructure**: plan-on-PR with state locking makes infra changes reviewable by diff and safe against concurrent edits. Our own laptops lost the ability to apply unreviewed changes — deliberately.
- **Why single sign-on via the GitHub organization**: vendors authenticate with identities they already have, protected by org-level MFA policy; we manage zero vendor passwords. Login is refused server-side for non-organization members, and an authenticated user with no assigned role can see and do nothing.
- **Why not a VPN for vendor access**: we don't manage vendor laptops; SSO with MFA at a WAF-protected endpoint provides the boundary a VPN would, without the support burden.

The POC also banked nineteen documented operational lessons (from cloud quota behavior to two genuinely subtle failure modes in the tooling) — pre-paid tuition for the production build, catalogued in `SETUP-GUIDE.md`.

---

## 6. What changes for internal customers

- **Your vendors ship faster and interrupt you less.** Merge-to-dev is minutes; vendors self-serve their status. You approve promotions to protected environments with one click, and that approval is on the record as yours.
- **Your service is isolated from everyone else's.** Per-team namespaces, quotas, and registries mean a noisy or compromised neighbor is contained by the platform, not by luck.
- **Conformance is enforced, not requested.** Applications must meet baseline standards (health endpoints, resource declarations, non-root images, no hardcoded secrets) or the platform refuses to deploy them — the checklist is executable, so review meetings about it disappear.
- **Asking "what's running?" has one answer.** The dashboards and the git history agree, because the git history is what's running.

**What we ask of you during migration**: nominate which of your services (and vendors) move in which wave; confirm each application meets the short conformance checklist (most containerized apps already do); attend one gate-approval walkthrough (~15 minutes — it is genuinely one button).

---

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Platform becomes a single point of failure | Deployed state lives in git; the platform itself rebuilds from automation in ~45 min (validated). Running applications are unaffected by platform-component outages — they keep serving |
| Key-person dependency on platform knowledge | Three documents capture build, operations, and access model; the bootstrap script encodes the build; every historical decision is in reviewed PRs |
| Vendor resistance to losing direct access | Vendors gain speed and visibility they never had; the POC's vendor experience (merge → watch it ship in minutes) is the selling point, not the concession |
| GitHub organization becomes security-critical | Acknowledged and specified: MFA enforcement, minimal default permissions, and team hygiene are documented prerequisites for the production org |
| Cost creep as services multiply | Single visible bill, documented scaling economics per layer, and consolidation levers identified in advance |

---

## 8. Recommendation and next steps

The POC has demonstrated every claim above on live infrastructure, including full disaster-recovery rebuild and the complete vendor journey performed by a real code change. The recommendation is to proceed to production:

1. **Provision the production foundation** (separate AWS accounts per environment under an organization; production GitHub org with the documented security settings) — the bootstrap automation applies unchanged.
2. **Migrate a first wave** of two or three friendly, well-containerized services end to end; use them to calibrate the conformance onboarding.
3. **Add the production environment** as a third promotion stage with its own approver group — mechanically identical to what exists, one more gate.
4. **Migrate remaining services in waves; decommission EC2 per service** as each cutover completes; consolidate regions as the map allows.

The POC environment remains available for demonstrations and can be parked at zero compute cost between them.

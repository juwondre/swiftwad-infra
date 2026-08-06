# Drills — proving the platform's failure behaviour

Procedures are only trustworthy once they've been run. These take ten minutes each, should be run against a non-production environment after any significant platform change, and each one has already found something.

## Drill 1 — Containment: a vendor ships a broken build

**Question**: does a bad vendor build stay contained in dev?

**Method**: in the sample service, make `main()` fail at startup (e.g. `log.Fatal("drill")`), merge it, and let the pipeline carry it.

```sh
# after merging the breakage:
kubectl --context dev -n <service> get pods -w
kubectl -n <kargo-project> get stages
```

**Result (2026-08-05, POC)** — contained, and more gracefully than expected:

| Stage | Behaviour |
|---|---|
| CI | **succeeded** — correct; a broken app still compiles and pushes |
| Kargo | discovered freight, auto-promoted to dev — correct; the gate is at staging, not dev |
| Dev pods | new replica `CrashLoopBackOff`; **the previous healthy replica kept serving** — the rolling update refused to retire it |
| Dev app health | `Progressing` — **never `Degraded`** (see the finding below) |
| Staging | untouched, `Healthy`, still on its verified image |

**Blast radius**: one non-serving pod. Dev itself stayed available.

**Finding → fix**: because the old replica keeps the rollout "in progress", a health-status alert never fires. Two rules now cover this: `PodCrashLooping` (restart-rate, fires in ~15m) and `ApplicationProgressingTooLong` (a rollout that never completes, 30m). Without the drill, both environments would have had a failure mode with no alert on it.

## Drill 2 — Rollback

**Question**: is `git revert` genuinely a rollback path?

**Method**: revert the breaking commit through the normal PR flow.

**Result (2026-08-05, POC)**: CI green → freight → promotion → dev back to `Healthy`, single Running pod, zero crashloops. No console actions, no manual image edits, no kubectl. Rollback is a git operation.

## Drill 3 — Governance enforcement

**Question**: do the branch rulesets actually bite, and does automation still flow past them?

```sh
git commit --allow-empty -m probe && git push       # expect rejection
git reset --hard origin/main
# then trigger a promotion and check the gitops repo's latest commit author
```

**Result (2026-08-05, POC)**: direct push to `main` rejected — *"push declined due to repository rule violations"* — while the next gitops commit was authored by **Kargo**, pushing through its deploy-key bypass. Humans gated, automation unimpeded. Both halves matter: a ruleset without the bypass would silently break every promotion.

## Drill 4 — Disaster recovery (do this annually, or before trusting the rebuild claim)

**Method**: `terraform destroy` a non-production environment, then rebuild with `bootstrap.sh all`.

**Result (2026-08-02, POC)**: 112 resources destroyed; full rebuild ≈45 minutes; end-to-end vendor loop re-passed. Findings folded into the gotcha index (destroy removes the terraform-created OIDC provider, so `create_github_oidc_provider` flips back to `true`; Secrets Manager entries need `--force-delete-without-recovery` on rebuild; the Kargo admin password is re-applied from whatever the script is fed).

## Suggested cadence

| Drill | When |
|---|---|
| Containment + rollback | after any change to the chart, Kargo config, or promotion policy |
| Governance | after any ruleset or deploy-key change |
| Disaster recovery | annually, and before onboarding the first production tenant |

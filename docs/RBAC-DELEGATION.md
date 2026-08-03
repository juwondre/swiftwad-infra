# Role delegation — who can do what, on which projects

Both UIs authenticate through one Dex + one GitHub org. Delegation is therefore always the same move: **create/choose a GitHub team, map it in git, merge a PR**. No individual names in config (rot), no permissions outside git (invisible), no default access (`policy.default: ""` in ArgoCD; unmatched claims resolve to nothing in Kargo).

## The persona matrix

| Persona | GitHub team | ArgoCD (per project) | Kargo (per project) | Kargo (global) |
|---|---|---|---|---|
| Vendor engineer | `<org>:vendor-<x>` | `applications get` + `logs get` on `vendor-<x>/*` | `kargo-viewer` | `kargo-project-lister` (list projects only) |
| Vendor lead | `<org>:vendor-<x>-leads` | + `applications sync` on `vendor-<x>/*-dev` only | `kargo-user` | same |
| Release manager | `<org>:engineering` | `applications *` + `logs get` on assigned projects | `kargo-admin` + `promote` on `staging` | cluster `kargo-admin` |
| Prod approver | `<org>:prod-approvers` | same as release manager | `promote` with `resourceNames: [prod]` | same |
| Platform admin | `<org>:platform` | built-in `role:admin` | cluster `kargo-admin` | cluster `kargo-admin` |

## ArgoCD — two knobs, don't conflate them

**AppProject = what the *applications* may do** (source repos, destination clusters/namespaces, allowed resource kinds). This bounds blast radius independent of any user. One AppProject per vendor.

**`policy.csv` = what the *users* may do.** Grammar: `p, <role>, <resource>, <action>, <project>/<app-pattern>, allow` then `g, <org>:<team>, <role>`. Lives in `bootstrap/argocd-values.yaml` (gitops repo).

```
# vendor engineer
p, role:vendor-acme-ro, applications, get, vendor-acme/*, allow
p, role:vendor-acme-ro, logs,         get, vendor-acme/*, allow
g, swiftwad:vendor-acme, role:vendor-acme-ro

# vendor lead: may re-sync ONLY the dev app (name-pattern scoping = env granularity)
p, role:vendor-acme-lead, applications, sync, vendor-acme/*-dev, allow
g, swiftwad:vendor-acme-leads, role:vendor-acme-lead

# release manager across the project
p, role:release-manager, applications, *,   vendor-acme/*, allow
p, role:release-manager, logs,         get, vendor-acme/*, allow
g, swiftwad:engineering, role:release-manager

# platform
g, swiftwad:platform, role:admin
```

Useful resources/actions beyond the basics: `exec create` (terminal into pods — grant to nobody vendor-shaped), `applications override`, `applications action/*` (restart deployments etc.), `applicationsets`, `clusters`, `repositories`. `scopes: "[groups]"` must be set for team mapping.

## Kargo — Kubernetes RBAC resolved via claims

A logged-in user acts with the **union** of every ServiceAccount whose `rbac.kargo.akuity.io/claim.<claim>: <value>` annotations match their OIDC claims (`groups` = GitHub team slugs as `<org>:<team>`; `email` works for individuals — avoid).

- **Project layer**: claim-annotated SAs in the project namespace + RoleBindings to `kargo-admin` / `kargo-user` / `kargo-viewer` (predefined ClusterRoles; namespaced binding = project-scoped meaning). File: `kargo/rbac-sso.yaml` (gitops repo).
- **Global layer**: claim-annotated SAs in `kargo-global` (registered via `api.oidc.globalServiceAccounts.namespaces`) + ClusterRoleBindings. Required at minimum for listing projects — without it every login sees "list is not permitted".

**Per-stage promotion rights** — the delegation that matters most:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: staging-promoter
  namespace: sample-api-delivery
rules:
  - apiGroups: ["kargo.akuity.io"]
    resources: ["stages"]
    verbs: ["promote"]
    resourceNames: ["staging"]     # prod gets its own role + its own team
```

Every Promotion is attributed to the actor's SSO identity (`create-actor` annotation, e.g. `email:someone@company.com`) — the approval audit trail is automatic.

Note: EKS access-policy admin does NOT satisfy the custom `promote` verb — even cluster operators need an explicit binding to promote via kubectl.

## Operational rules

1. **Access changes are PRs** to the gitops repo — same review and audit trail as code. Nothing is granted from a UI.
2. **Teams, never individuals.** Onboarding = add to team; offboarding = remove from team; access dies with the SSO session.
3. **New vendor recipe**: GitHub team → ArgoCD AppProject + policy block → Kargo project SAs/bindings → done. Existing vendors' config is never edited.
4. **Least privilege at the top too**: `exec`, cluster-scoped ArgoCD resources, and the `promote` verb on prod are deliberate, named grants — not part of any broad role.
5. Past ~5 vendors, generate the per-vendor boilerplate (terraform `templatefile` or a script) so the pattern stays uniform.

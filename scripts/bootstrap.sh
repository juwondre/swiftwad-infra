#!/usr/bin/env bash
# Bootstrap the vendor-isolated GitOps platform end to end.
# Mirrors the exact build documented in docs/PLATFORM-SETUP.md.
#
# Usage:
#   Edit the CONFIG block, then run phases in order:
#     ./bootstrap.sh state-bucket
#     ./bootstrap.sh terraform
#     ./bootstrap.sh argocd
#     ./bootstrap.sh spokes
#     ./bootstrap.sh kargo
#     ./bootstrap.sh atlantis
#     ./bootstrap.sh observability   # if enable_observability = true
#     ./bootstrap.sh verify
#   or everything: ./bootstrap.sh all
#
# Idempotent-ish: phases are safe to re-run; existing resources are skipped or
# upgraded in place. Requires: aws, terraform, helm, kubectl, gh, jq, openssl, htpasswd.

set -euo pipefail

############################ CONFIG — edit me ############################
export AWS_PROFILE="swiftwad"                # local auth; in-cluster is IRSA
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="905418331655"

GITHUB_ORG="juwondre"                        # org or user owning the repos
INFRA_REPO="swiftwad-infra"
GITOPS_REPO="swiftwad-gitops"

STATE_BUCKET="swiftwad-tf-state-${AWS_ACCOUNT_ID}"

# Kargo project namespace for the reference service — must match the project
# name in the gitops repo's kargo/project.yaml (SERVICE + "-delivery").
KARGO_PROJECT_NS="sample-api-delivery"

HUB_ENV="staging"                            # cluster hosting argocd/kargo/atlantis
SPOKE_ENVS=("dev")                           # registered as argocd spokes
CLUSTER_PREFIX="swiftwad"                    # clusters are ${CLUSTER_PREFIX}-${env}

KARGO_ADMIN_PASSWORD="${KARGO_ADMIN_PASSWORD:-}"     # export before running, or set here
ATLANTIS_GITHUB_USER="juwondre"
ATLANTIS_GITHUB_TOKEN="${ATLANTIS_GITHUB_TOKEN:-$(gh auth token)}"  # GitHub App creds in real project

# Required when the gitops repo is PRIVATE: a GitHub token with read access to
# it (classic PAT with repo scope is the path org policies accept most often;
# mind org PAT-lifetime caps — an over-long expiry is silently rejected).
# Leave empty for public gitops repos.
GITOPS_READ_TOKEN="${GITOPS_READ_TOKEN:-}"

# IAM principals that keep kubectl admin on every cluster (day-one access
# entries — see the Atlantis "cluster creator" gotcha in PLATFORM-SETUP.md).
OPERATOR_ARNS=()                             # e.g. ("arn:aws:iam::123:role/platform-ops")

# Feed the config block into terraform so the knobs actually drive it.
export TF_VAR_cluster_prefix="$CLUSTER_PREFIX"
export TF_VAR_region="$AWS_REGION"
if [ ${#OPERATOR_ARNS[@]} -gt 0 ]; then
  TF_VAR_operator_principal_arns=$(printf '"%s",' "${OPERATOR_ARNS[@]}")
  export TF_VAR_operator_principal_arns="[${TF_VAR_operator_principal_arns%,}]"
fi

# Directory of this repo's terraform (relative to this script)
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
# Local checkout of the gitops repo (for bootstrap-time values/manifests)
GITOPS_DIR="${GITOPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../${GITOPS_REPO}" 2>/dev/null && pwd || echo "")}"
##########################################################################

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
HUB_CLUSTER="${CLUSTER_PREFIX}-${HUB_ENV}"
HUB_KC="$WORKDIR/kc-hub"

log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing tool: $1"; }

preflight() {
  for t in aws terraform helm kubectl gh jq openssl htpasswd; do need "$t"; done
  aws sts get-caller-identity >/dev/null || die "AWS auth failed for profile $AWS_PROFILE"
  # gh auth status exits non-zero if ANY configured account has a stale token,
  # even when the active one is fine — test the active token instead.
  gh auth token >/dev/null 2>&1 || die "gh CLI not authenticated (no active token)"
  [ -n "$GITOPS_DIR" ] && [ -d "$GITOPS_DIR" ] || die "GITOPS_DIR not found — clone ${GITHUB_ORG}/${GITOPS_REPO} next to this repo or export GITOPS_DIR"
  local quota
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
    --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")
  log "preflight ok (vCPU quota: ${quota} — each t3.medium uses 2; POC needs ~10 free)"
}

phase_state_bucket() {
  log "state bucket: s3://${STATE_BUCKET}"
  if ! aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    if [ "$AWS_REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$STATE_BUCKET"
    else
      aws s3api create-bucket --bucket "$STATE_BUCKET" \
        --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
    fi
  fi
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled
}

phase_terraform() {
  log "terraform apply (VPC, EKS clusters, ECR, IAM) — 20-30 min on first run"
  terraform -chdir="$TF_DIR" init -input=false
  terraform -chdir="$TF_DIR" apply -input=false -auto-approve
}

hub_kubeconfig() {
  aws eks update-kubeconfig --name "$HUB_CLUSTER" --kubeconfig "$HUB_KC" >/dev/null
}

phase_argocd() {
  log "argocd hub on ${HUB_CLUSTER}"
  hub_kubeconfig
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm --kubeconfig "$HUB_KC" upgrade --install argocd argo/argo-cd \
    -n argocd --create-namespace \
    -f "$GITOPS_DIR/bootstrap/argocd-values.yaml" --wait --timeout 8m
  # Private gitops repo: ArgoCD needs its own read credential (found live: a
  # private repo leaves the root app permanently unsynced with only an auth
  # condition to show for it).
  if [ -n "$GITOPS_READ_TOKEN" ]; then
    kubectl --kubeconfig "$HUB_KC" -n argocd create secret generic repo-gitops \
      --from-literal=type=git \
      --from-literal=url="https://github.com/${GITHUB_ORG}/${GITOPS_REPO}" \
      --from-literal=username=x-access-token \
      --from-literal=password="$GITOPS_READ_TOKEN" \
      --dry-run=client -o yaml | kubectl --kubeconfig "$HUB_KC" apply -f -
    kubectl --kubeconfig "$HUB_KC" -n argocd label secret repo-gitops \
      argocd.argoproj.io/secret-type=repository --overwrite
    log "argocd repository credential configured for private gitops repo"
  fi

  kubectl --kubeconfig "$HUB_KC" apply -f "$GITOPS_DIR/argocd/root-app.yaml"
  log "argocd installed; root app applied"
}

phase_spokes() {
  # Declarative spoke registration: SA + token on the spoke, cluster Secret on
  # the hub. Avoids the argocd CLI entirely (see PLATFORM-SETUP.md phase 3).
  hub_kubeconfig
  for env in "${SPOKE_ENVS[@]}"; do
    local cluster="${CLUSTER_PREFIX}-${env}" kc="$WORKDIR/kc-${env}"
    log "registering spoke: ${cluster}"
    aws eks update-kubeconfig --name "$cluster" --kubeconfig "$kc" >/dev/null

    kubectl --kubeconfig "$kc" -n kube-system create serviceaccount argocd-manager \
      --dry-run=client -o yaml | kubectl --kubeconfig "$kc" apply -f -
    kubectl --kubeconfig "$kc" create clusterrolebinding argocd-manager-role-binding \
      --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager \
      --dry-run=client -o yaml | kubectl --kubeconfig "$kc" apply -f -
    kubectl --kubeconfig "$kc" apply -f - <<TOKEN
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-long-lived-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
TOKEN
    # The token controller populates the secret asynchronously — poll for it.
    local token="" endpoint ca
    for _ in $(seq 1 20); do
      token=$(kubectl --kubeconfig "$kc" -n kube-system get secret argocd-manager-long-lived-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
      [ -n "$token" ] && break
      sleep 3
    done
    [ -n "$token" ] || die "spoke ${cluster}: service account token never populated"
    endpoint=$(aws eks describe-cluster --name "$cluster" --query 'cluster.endpoint' --output text)
    ca=$(aws eks describe-cluster --name "$cluster" --query 'cluster.certificateAuthority.data' --output text)

    kubectl --kubeconfig "$HUB_KC" -n argocd apply -f - <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster}
  server: ${endpoint}
  config: |
    {"bearerToken": "${token}", "tlsClientConfig": {"caData": "${ca}"}}
SECRET
  done
}

phase_kargo() {
  [ -n "$KARGO_ADMIN_PASSWORD" ] || die "set KARGO_ADMIN_PASSWORD"
  hub_kubeconfig
  log "cert-manager + kargo on ${HUB_CLUSTER}"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm --kubeconfig "$HUB_KC" upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager --create-namespace --set crds.enabled=true --wait --timeout 6m

  local hash signkey role_arn
  hash=$(htpasswd -bnBC 10 "" "$KARGO_ADMIN_PASSWORD" | tr -d ':\n')
  signkey=$(openssl rand -base64 32 | tr -d '=+/')
  role_arn=$(terraform -chdir="$TF_DIR" output -raw kargo_controller_role_arn)
  # Non-secret config (SSO via ArgoCD's Dex, ALB ingress) lives in the gitops
  # repo; only the secrets are injected here.
  helm --kubeconfig "$HUB_KC" upgrade --install kargo \
    oci://ghcr.io/akuity/kargo-charts/kargo -n kargo --create-namespace \
    -f "$GITOPS_DIR/bootstrap/kargo-values.yaml" \
    --set api.adminAccount.passwordHash="$hash" \
    --set api.adminAccount.tokenSigningKey="$signkey" \
    --set "controller.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${role_arn}" \
    --wait --timeout 8m

  log "kargo delivery config + git credentials"
  kubectl --kubeconfig "$HUB_KC" apply -f "$GITOPS_DIR/kargo/project.yaml"
  for _ in $(seq 1 20); do
    kubectl --kubeconfig "$HUB_KC" get ns ${KARGO_PROJECT_NS} >/dev/null 2>&1 && break; sleep 3
  done

  if ! kubectl --kubeconfig "$HUB_KC" -n ${KARGO_PROJECT_NS} get secret kargo-gitops-creds >/dev/null 2>&1; then
    ssh-keygen -t ed25519 -N "" -C "kargo-promoter" -f "$WORKDIR/kargo_key" -q
    gh repo deploy-key add "$WORKDIR/kargo_key.pub" -R "${GITHUB_ORG}/${GITOPS_REPO}" \
      --allow-write --title "kargo-promoter"
    kubectl --kubeconfig "$HUB_KC" create secret generic kargo-gitops-creds \
      -n ${KARGO_PROJECT_NS} \
      --from-literal=repoURL="ssh://git@github.com/${GITHUB_ORG}/${GITOPS_REPO}.git" \
      --from-file=sshPrivateKey="$WORKDIR/kargo_key"
    kubectl --kubeconfig "$HUB_KC" label secret kargo-gitops-creds \
      -n ${KARGO_PROJECT_NS} kargo.akuity.io/cred-type=git
  fi

  kubectl --kubeconfig "$HUB_KC" apply \
    -f "$GITOPS_DIR/kargo/warehouse.yaml" \
    -f "$GITOPS_DIR/kargo/stage-dev.yaml" \
    -f "$GITOPS_DIR/kargo/stage-staging.yaml"

  # Promotion approvers need the custom 'promote' verb — EKS admin policies
  # don't cover it (PLATFORM-SETUP.md phase 4).
  kubectl --kubeconfig "$HUB_KC" apply -f - <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: stage-promoter
  namespace: ${KARGO_PROJECT_NS}
rules:
  - apiGroups: ["kargo.akuity.io"]
    resources: ["stages"]
    verbs: ["promote"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: stage-promoter-bootstrap
  namespace: ${KARGO_PROJECT_NS}
subjects:
  - kind: User
    name: $(aws sts get-caller-identity --query Arn --output text)
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: stage-promoter
  apiGroup: rbac.authorization.k8s.io
RBAC
}

phase_atlantis() {
  hub_kubeconfig
  log "atlantis on ${HUB_CLUSTER}"

  # Current EKS ships no default StorageClass (gp2 exists but is unmarked), so
  # any PVC without an explicit class stays Pending forever. Provide gp3.
  kubectl --kubeconfig "$HUB_KC" apply -f - <<'SC'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  type: gp3
  encrypted: "true"
SC
  local secret_file="$TF_DIR/../.atlantis-webhook-secret" webhook_secret role_arn
  if [ -f "$secret_file" ]; then webhook_secret=$(cat "$secret_file"); else
    webhook_secret=$(openssl rand -hex 20); printf '%s' "$webhook_secret" > "$secret_file"
  fi
  role_arn=$(terraform -chdir="$TF_DIR" output -raw atlantis_role_arn)

  helm repo add runatlantis https://runatlantis.github.io/helm-charts >/dev/null 2>&1 || true
  helm --kubeconfig "$HUB_KC" upgrade --install atlantis runatlantis/atlantis \
    -n atlantis --create-namespace \
    --set orgAllowlist="github.com/${GITHUB_ORG}/${INFRA_REPO}" \
    --set github.user="$ATLANTIS_GITHUB_USER" \
    --set github.token="$ATLANTIS_GITHUB_TOKEN" \
    --set github.secret="$webhook_secret" \
    --set service.type=LoadBalancer \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${role_arn}" \
    --set volumeClaim.dataStorage=5Gi \
    --set volumeClaim.storageClassName=gp3 \
    --wait --timeout 8m

  log "waiting for load balancer hostname"
  local host=""
  for _ in $(seq 1 40); do
    host=$(kubectl --kubeconfig "$HUB_KC" -n atlantis get svc atlantis \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    [ -n "$host" ] && break; sleep 10
  done
  [ -n "$host" ] || die "atlantis LB never got a hostname"

  helm --kubeconfig "$HUB_KC" upgrade atlantis runatlantis/atlantis -n atlantis \
    --reuse-values --set atlantisUrl="http://${host}" --wait --timeout 5m

  log "webhook on ${GITHUB_ORG}/${INFRA_REPO} -> http://${host}/events"
  local existing
  existing=$(gh api "repos/${GITHUB_ORG}/${INFRA_REPO}/hooks" \
    --jq "[.[] | select(.config.url == \"http://${host}/events\")] | length")
  if [ "$existing" = "0" ]; then
    gh api "repos/${GITHUB_ORG}/${INFRA_REPO}/hooks" -X POST \
      -f name=web -F active=true \
      -f 'events[]=push' -f 'events[]=pull_request' \
      -f 'events[]=pull_request_review' -f 'events[]=issue_comment' \
      -f config[url]="http://${host}/events" \
      -f config[content_type]=json \
      -f config[secret]="$webhook_secret" >/dev/null
  fi
  log "atlantis ready at http://${host}"
}

phase_observability() {
  hub_kubeconfig
  log "observability — collectors and Grafana are ArgoCD Applications; this seeds and waits"

  local obs
  obs=$(terraform -chdir="$TF_DIR" output -json observability 2>/dev/null || echo "null")
  [ "$obs" = "null" ] && die "observability backends absent — set enable_observability = true in tfvars and apply first"

  log "AMP remote-write: $(echo "$obs" | jq -r .amp_remote_write)"
  log "AMP query:        $(echo "$obs" | jq -r .amp_query_url)"
  log "log group:        $(echo "$obs" | jq -r .log_group)"

  # Grafana's GitHub OAuth app is a browser step; seed a placeholder so the
  # ExternalSecret resolves and Grafana starts (SSO fails until the real values
  # land — same pattern as the ArgoCD Dex secret).
  if ! aws secretsmanager get-secret-value --secret-id grafana/github-oauth \
       --query SecretString --output text >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id grafana/github-oauth \
      --secret-string '{"clientID":"placeholder","clientSecret":"placeholder"}' >/dev/null
    log "seeded placeholder Grafana OAuth credentials — replace with the real app's values"
  fi

  log "waiting for collectors and Grafana"
  for _ in $(seq 1 40); do
    local prom fb graf
    prom=$(kubectl --kubeconfig "$HUB_KC" -n observability get sts,deploy -o name 2>/dev/null | grep -c prometheus || true)
    fb=$(kubectl --kubeconfig "$HUB_KC" -n observability get ds -o name 2>/dev/null | grep -c fluent-bit || true)
    graf=$(kubectl --kubeconfig "$HUB_KC" -n observability get deploy grafana -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "${prom:-0}" -ge 1 ] && [ "${fb:-0}" -ge 1 ] && [ "${graf:-0}" -ge 1 ]; then
      log "observability stack up"
      kubectl --kubeconfig "$HUB_KC" -n observability get pods
      return 0
    fi
    sleep 15
  done
  log "WARNING: stack not fully ready — check: kubectl -n argocd get app grafana prometheus-agent fluent-bit"
}

phase_verify() {
  hub_kubeconfig
  log "argocd applications"
  kubectl --kubeconfig "$HUB_KC" -n argocd get applications \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
  log "kargo stages"
  kubectl --kubeconfig "$HUB_KC" -n ${KARGO_PROJECT_NS} get warehouses,stages,freight 2>/dev/null || true
  log "atlantis"
  kubectl --kubeconfig "$HUB_KC" -n atlantis get pods 2>/dev/null || true
  log "done — see docs/PLATFORM-SETUP.md phase 7 for the full checklist"
}

main() {
  local phase="${1:-}"
  preflight
  case "$phase" in
    state-bucket) phase_state_bucket ;;
    terraform)    phase_terraform ;;
    argocd)       phase_argocd ;;
    spokes)       phase_spokes ;;
    kargo)        phase_kargo ;;
    atlantis)     phase_atlantis ;;
    observability) phase_observability ;;
    verify)       phase_verify ;;
    all) phase_state_bucket; phase_terraform; phase_argocd; phase_spokes
         phase_kargo; phase_atlantis
         [ "$(terraform -chdir="$TF_DIR" output -json observability 2>/dev/null || echo null)" != "null" ] && phase_observability
         phase_verify ;;
    *) die "usage: $0 {state-bucket|terraform|argocd|spokes|kargo|atlantis|observability|verify|all}" ;;
  esac
}

main "$@"

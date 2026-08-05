variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_prefix" {
  type    = string
  default = "swiftwad"
}

variable "vpc_name" {
  type    = string
  default = "swiftwad-poc"
}

variable "domain" {
  description = "Base domain for platform UIs (argocd.<domain>, kargo.<domain>)"
  type        = string
  default     = "swiftwad.com"
}

variable "service_name" {
  description = "Name stem for the reference service's IAM role (gh-actions-<service_name>)"
  type        = string
  default     = "swiftwad-sample-api"
}

variable "ecr_repo_name" {
  description = "ECR repository name for the reference service"
  type        = string
  default     = "sample-api"
}

variable "create_github_oidc_provider" {
  description = "Fresh accounts have no GitHub OIDC provider — set true to create it; false references the existing one"
  type        = bool
  default     = false
}

variable "create_wildcard_cert" {
  description = "Request a new *.<domain> ACM cert (DNS validation records output for whoever serves the zone). False uses wildcard_cert_arn"
  type        = bool
  default     = false
}

variable "validate_in_route53" {
  description = "Auto-validate the created cert via var.public_zone_id (zone must be authoritative). Only meaningful with create_wildcard_cert = true"
  type        = bool
  default     = false
}

variable "wildcard_cert_arn" {
  description = "Existing ACM wildcard cert ARN, used when create_wildcard_cert is false"
  type        = string
  default     = "arn:aws:acm:us-east-1:905418331655:certificate/0ae80028-4f78-4e82-ac89-10ec9480ef5f"
}

variable "public_zone_id" {
  description = "Route53 hosted zone external-dns may write to"
  type        = string
  default     = "Z0448614337KG0YUUT6NR" # swiftwad.com
}

variable "operator_principal_arns" {
  description = "IAM principals granted cluster-admin on every cluster via access entries (humans/roles that need kubectl or the EKS console resource view)"
  type        = list(string)
  default = [
    "arn:aws:iam::905418331655:user/swiftwad-deploy",
    # IAM Identity Center admins (console access). Access entries validate the
    # principal exists, so the FULL pathed ARN is required (it's the legacy
    # aws-auth ConfigMap that wanted paths stripped — not access entries).
    # NOTE: the hash suffix changes if the permission set is ever recreated.
    "arn:aws:iam::905418331655:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_e98b01fa7eb06fb6",
  ]
}

variable "viewer_principal_arns" {
  description = "IAM principals granted read-only cluster access (EKS console browsing, kubectl get) — no mutations"
  type        = list(string)
  default = [
    "arn:aws:iam::905418331655:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_engineering-permissions_3c971c4a142a7cde",
  ]
}

variable "cluster_version" {
  type    = string
  default = "1.34"
}

variable "environments" {
  description = "Cluster environments to create"
  type        = list(string)
  default     = ["dev", "staging"]
}

variable "node_group_sizes" {
  type = map(object({
    min     = number
    desired = number
    max     = number
  }))
  default = {
    dev     = { min = 2, desired = 2, max = 3 }
    staging = { min = 3, desired = 3, max = 4 } # hub runs the platform stack
  }
}

variable "sample_app_repo" {
  description = "GitHub repo allowed to push the sample-api image"
  type        = string
  default     = "juwondre/swiftwad-sample-api"
}

variable "sample_app_repo_id_pinned" {
  description = "Same repo in GitHub's ID-pinned OIDC sub format (from GET /repos/{owner}/{repo}/actions/oidc/customization/sub)"
  type        = string
  default     = "juwondre@98793109/swiftwad-sample-api@1320664713"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_prefix" {
  type    = string
  default = "swiftwad"
}

variable "public_zone_id" {
  description = "Route53 hosted zone external-dns may write to"
  type        = string
  default     = "Z0448614337KG0YUUT6NR" # swiftwad.com
}

variable "operator_principal_arns" {
  description = "IAM principals granted cluster-admin on every cluster via access entries (humans/roles that need kubectl)"
  type        = list(string)
  default     = []
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

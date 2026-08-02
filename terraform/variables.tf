variable "region" {
  type    = string
  default = "us-east-1"
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

# Account is capped at 16 On-Demand vCPUs (increase pending); dev runs 1 node
# until the quota lands, then bump desired back to 2.
variable "node_group_sizes" {
  type = map(object({
    min     = number
    desired = number
    max     = number
  }))
  default = {
    dev     = { min = 1, desired = 1, max = 3 }
    staging = { min = 2, desired = 2, max = 3 }
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

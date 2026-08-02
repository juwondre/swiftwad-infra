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

variable "sample_app_repo" {
  description = "GitHub repo allowed to push the sample-api image"
  type        = string
  default     = "juwondre/swiftwad-sample-api"
}

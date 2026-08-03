output "cluster_endpoints" {
  value = { for k, m in module.eks : k => m.cluster_endpoint }
}

output "cluster_names" {
  value = { for k, m in module.eks : k => m.cluster_name }
}

output "ecr_repository_url" {
  value = aws_ecr_repository.sample_api.repository_url
}

output "gh_actions_role_arn" {
  value = aws_iam_role.gh_actions_sample_api.arn
}

output "nat_egress_ip" {
  description = "Permanent egress IP — the Cloudflare token's IP filter must match this"
  value       = aws_eip.nat.public_ip
}

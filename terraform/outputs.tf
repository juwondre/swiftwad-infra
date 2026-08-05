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

# Everything the gitops repo's environment render needs, in one place:
#   terraform output -json platform_config > ../../<gitops-repo>/environments/<env>.json
output "platform_config" {
  value = {
    account_id        = data.aws_caller_identity.current.account_id
    region            = var.region
    cluster_prefix    = var.cluster_prefix
    domain            = var.domain
    argocd_host       = "argocd.${var.domain}"
    kargo_host        = "kargo.${var.domain}"
    vpc_id            = module.vpc.vpc_id
    nat_egress_ip     = aws_eip.nat.public_ip
    wildcard_cert_arn = local.wildcard_cert_arn
    waf_acl_arn       = var.enable_waf ? aws_wafv2_web_acl.argocd[0].arn : ""
    ecr_registry      = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    ecr_repository    = aws_ecr_repository.sample_api.repository_url
    cluster_names     = { for k, m in module.eks : k => m.cluster_name }
    roles = {
      gh_actions       = aws_iam_role.gh_actions_sample_api.arn
      kargo_controller = aws_iam_role.kargo_controller.arn
      atlantis         = aws_iam_role.atlantis.arn
      alb_controller   = aws_iam_role.platform["alb-controller"].arn
      external_dns     = aws_iam_role.platform["external-dns"].arn
      external_secrets = aws_iam_role.platform["external-secrets"].arn
    }
  }
}

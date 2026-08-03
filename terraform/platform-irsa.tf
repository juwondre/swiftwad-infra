# IRSA roles for platform controllers on the hub (staging) cluster:
# aws-load-balancer-controller, external-dns, external-secrets. All are
# deployed as ArgoCD Applications from the gitops repo; terraform only owns
# their AWS identities.

locals {
  hub_oidc_arn = module.eks["staging"].oidc_provider_arn
  hub_oidc     = module.eks["staging"].oidc_provider

  platform_irsa = {
    alb-controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
    external-dns = {
      namespace       = "external-dns"
      service_account = "external-dns"
    }
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

data "aws_iam_policy_document" "platform_trust" {
  for_each = local.platform_irsa

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.hub_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.hub_oidc}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.hub_oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "platform" {
  for_each = local.platform_irsa

  name               = "${each.key}-${var.cluster_prefix}-staging"
  assume_role_policy = data.aws_iam_policy_document.platform_trust[each.key].json
}

# Official upstream policy, vendored at terraform/policies/.
resource "aws_iam_role_policy" "alb_controller" {
  name   = "alb-controller"
  role   = aws_iam_role.platform["alb-controller"].id
  policy = file("${path.module}/policies/alb-controller-iam-policy.json")
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.public_zone_id}"]
  }

  statement {
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53-swiftwad-com"
  role   = aws_iam_role.platform["external-dns"].id
  policy = data.aws_iam_policy_document.external_dns.json
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:argocd/*"]
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "secretsmanager-argocd"
  role   = aws_iam_role.platform["external-secrets"].id
  policy = data.aws_iam_policy_document.external_secrets.json
}

# Container for the Dex GitHub OAuth credentials. The value is set out-of-band
# (never in terraform state or git): aws secretsmanager put-secret-value.
resource "aws_secretsmanager_secret" "dex_github" {
  name        = "argocd/dex-github"
  description = "GitHub OAuth app credentials for ArgoCD Dex SSO (keys: clientID, clientSecret)"
}

output "platform_role_arns" {
  value = { for k, r in aws_iam_role.platform : k => r.arn }
}

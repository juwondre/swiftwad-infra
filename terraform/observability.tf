# Observability backends: metrics and dashboards are AWS-managed so the
# clusters stay stateless and disposable (the rebuild story depends on it).
# Collectors themselves run in-cluster as ArgoCD Applications.

resource "aws_prometheus_workspace" "platform" {
  count = var.enable_observability ? 1 : 0

  alias = "${var.cluster_prefix}-platform"
}

resource "aws_cloudwatch_log_group" "workloads" {
  count = var.enable_observability ? 1 : 0

  name              = "/${var.cluster_prefix}/workloads"
  retention_in_days = var.log_retention_days
}

# ── IRSA: Prometheus agent (remote-write to AMP) ──
data "aws_iam_policy_document" "amp_write_trust" {
  for_each = var.enable_observability ? toset(var.environments) : toset([])

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks[each.key].oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[each.key].oidc_provider}:sub"
      values   = ["system:serviceaccount:observability:prometheus-agent"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[each.key].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "amp_write" {
  for_each = var.enable_observability ? toset(var.environments) : toset([])

  name               = "amp-write-${var.cluster_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.amp_write_trust[each.key].json
}

resource "aws_iam_role_policy" "amp_write" {
  for_each = var.enable_observability ? toset(var.environments) : toset([])

  name = "amp-remote-write"
  role = aws_iam_role.amp_write[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["aps:RemoteWrite", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata"]
      Resource = aws_prometheus_workspace.platform[0].arn
    }]
  })
}

# ── IRSA: Fluent Bit (logs to CloudWatch) ──
data "aws_iam_policy_document" "fluentbit_trust" {
  for_each = var.enable_observability ? toset(var.environments) : toset([])

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks[each.key].oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[each.key].oidc_provider}:sub"
      values   = ["system:serviceaccount:observability:fluent-bit"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[each.key].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fluentbit" {
  for_each = var.enable_observability ? toset(var.environments) : toset([])

  name               = "fluentbit-${var.cluster_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.fluentbit_trust[each.key].json
}

resource "aws_iam_role_policy" "fluentbit" {
  for_each = var.enable_observability ? toset(var.environments) : toset([])

  name = "cloudwatch-logs-write"
  role = aws_iam_role.fluentbit[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:CreateLogGroup",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups",
      ]
      Resource = "${aws_cloudwatch_log_group.workloads[0].arn}:*"
    }]
  })
}

output "observability" {
  value = var.enable_observability ? {
    amp_workspace_id  = aws_prometheus_workspace.platform[0].id
    amp_remote_write  = "${aws_prometheus_workspace.platform[0].prometheus_endpoint}api/v1/remote_write"
    amp_query_url     = aws_prometheus_workspace.platform[0].prometheus_endpoint
    log_group         = aws_cloudwatch_log_group.workloads[0].name
    amp_write_roles   = { for k, r in aws_iam_role.amp_write : k => r.arn }
    fluentbit_roles   = { for k, r in aws_iam_role.fluentbit : k => r.arn }
  } : null
}

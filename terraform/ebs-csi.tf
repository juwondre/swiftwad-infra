# EBS CSI driver for both clusters. EKS ships no storage provisioner by
# default — without this, any PVC (e.g. Atlantis's data volume) stays Pending
# forever with "unbound immediate PersistentVolumeClaims".
data "aws_iam_policy_document" "ebs_csi_trust" {
  for_each = toset(var.environments)

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks[each.key].oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[each.key].oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[each.key].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  for_each = toset(var.environments)

  name               = "ebs-csi-${var.cluster_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust[each.key].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  for_each = toset(var.environments)

  role       = aws_iam_role.ebs_csi[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  for_each = toset(var.environments)

  cluster_name             = module.eks[each.key].cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi[each.key].arn
}

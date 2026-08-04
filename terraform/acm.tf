# Wildcard certificate for platform UIs. The POC reused a pre-existing cert
# (create_wildcard_cert = false + wildcard_cert_arn); a fresh environment sets
# create_wildcard_cert = true and places the validation CNAMEs (see the
# acm_validation_records output) wherever the domain's DNS actually lives —
# check with `dig +short NS <domain>` first, it may not be Route53.
resource "aws_acm_certificate" "wildcard" {
  count = var.create_wildcard_cert ? 1 : 0

  domain_name               = "*.${var.domain}"
  subject_alternative_names = [var.domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  wildcard_cert_arn = var.create_wildcard_cert ? aws_acm_certificate.wildcard[0].arn : var.wildcard_cert_arn
}

output "acm_validation_records" {
  description = "CNAMEs to create at the domain's DNS host; the cert stays PENDING_VALIDATION until they exist"
  value = var.create_wildcard_cert ? [
    for o in aws_acm_certificate.wildcard[0].domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ] : []
}

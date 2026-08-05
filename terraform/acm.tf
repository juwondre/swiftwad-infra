# Wildcard certificate for platform UIs.
#
# Three modes:
#   create_wildcard_cert = false                       -> reuse wildcard_cert_arn (the POC)
#   create_wildcard_cert = true,  validate_in_route53 = false
#     -> request cert; place the acm_validation_records output at the domain's
#        DNS host by hand (when public DNS is NOT Route53 — check `dig NS`)
#   create_wildcard_cert = true,  validate_in_route53 = true
#     -> fully automatic: validation CNAMEs written to var.public_zone_id and
#        the apply blocks until the cert is ISSUED. Requires the zone to be
#        authoritative for the domain.
resource "aws_acm_certificate" "wildcard" {
  count = var.create_wildcard_cert ? 1 : 0

  domain_name               = "*.${var.domain}"
  subject_alternative_names = [var.domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "wildcard_validation" {
  for_each = var.create_wildcard_cert && var.validate_in_route53 ? {
    for dvo in aws_acm_certificate.wildcard[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = var.public_zone_id
  allow_overwrite = true
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "wildcard" {
  count = var.create_wildcard_cert && var.validate_in_route53 ? 1 : 0

  certificate_arn         = aws_acm_certificate.wildcard[0].arn
  validation_record_fqdns = [for r in aws_route53_record.wildcard_validation : r.fqdn]
}

locals {
  # Referencing the validation resource's arn forces the apply to wait for
  # ISSUED, so downstream consumers never see a pending cert.
  wildcard_cert_arn = (
    var.create_wildcard_cert && var.validate_in_route53 ? aws_acm_certificate_validation.wildcard[0].certificate_arn :
    var.create_wildcard_cert ? aws_acm_certificate.wildcard[0].arn :
    var.wildcard_cert_arn
  )
}

output "acm_validation_records" {
  description = "Only populated in manual-validation mode: CNAMEs to place at the domain's DNS host"
  value = var.create_wildcard_cert && !var.validate_in_route53 ? [
    for o in aws_acm_certificate.wildcard[0].domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ] : []
}

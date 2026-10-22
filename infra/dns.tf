# Optional (Step 6): point a name like w8.ebotprog.ink at the ALB.
# Skipped entirely while var.domain_name is empty.
data "aws_route53_zone" "this" {
  count = var.domain_name == "" ? 0 : 1
  name  = var.hosted_zone_name
}

resource "aws_route53_record" "app" {
  count = var.domain_name == "" ? 0 : 1

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

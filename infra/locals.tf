locals {
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # One entry per ECS service. Everything else (target groups, listeners,
  # services, autoscaling, deployment groups) is generated from this map.
  services = {
    frontend = {
      repo           = "crud-nextjs-frontend"
      container_port = 3000
      listener_port  = 80
      health_path    = "/"
      health_matcher = "200-399" # Next.js may redirect "/" (e.g. to /login)
    }
    backend = {
      repo           = "crud-parse-server-backend"
      container_port = 1337
      listener_port  = 1337
      health_path    = "/parse/health"
      health_matcher = "200"
    }
  }

  # Public address users and browsers use
  public_host      = var.domain_name != "" ? var.domain_name : aws_lb.this.dns_name
  public_parse_url = "http://${local.public_host}:1337/parse"
}

output "app_url" {
  description = "Open this in the browser"
  value       = "http://${local.public_host}"
}

output "parse_server_url" {
  description = "Set as GitHub repository variable PARSE_SERVER_URL"
  value       = local.public_parse_url
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "nat_public_ip" {
  description = "Allow this IP (/32) in MongoDB Atlas → Network Access"
  value       = aws_eip.nat.public_ip
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "frontend_service" {
  value = aws_ecs_service.svc["frontend"].name
}

output "backend_service" {
  value = aws_ecs_service.svc["backend"].name
}

output "frontend_task_definition" {
  value = aws_ecs_task_definition.svc["frontend"].arn
}

output "backend_task_definition" {
  value = aws_ecs_task_definition.svc["backend"].arn
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

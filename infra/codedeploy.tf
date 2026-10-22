resource "aws_codedeploy_app" "this" {
  name             = "${var.project}-app"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "svc" {
  for_each = local.services

  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = "${var.project}-${each.key}-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  # Green never becomes healthy → deployment fails → users stay on blue
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.blue_termination_wait_minutes
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.this.name
    service_name = aws_ecs_service.svc[each.key].name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.prod[each.key].arn]
      }

      target_group {
        name = aws_lb_target_group.blue[each.key].name
      }

      target_group {
        name = aws_lb_target_group.green[each.key].name
      }
    }
  }
}

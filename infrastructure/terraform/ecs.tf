# ==============================================================================
# Core ECS: cluster, Fargate task definition, HA service and autoscaling.
# ==============================================================================

resource "aws_ecs_cluster" "mm_bet" {
  name = "mm-bet-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/mm-bet-${var.environment}-user-service"
  retention_in_days = var.log_retention_days
}

locals {
  # RDS/Redis endpoints resolved either from resources below or injected vars.
  db_endpoint = var.create_rds ? aws_db_instance.app[0].address : var.existing_rds_endpoint
  redis_host  = var.create_redis ? aws_elasticache_replication_group.app[0].primary_endpoint_address : var.existing_redis_endpoint

  container_defs = jsonencode([
    {
      name      = "user-service"
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.api_port
          hostPort      = 0 # awsvpc network mode ignores host port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "DB_HOST", value = local.db_endpoint },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_USER", value = var.db_username },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_SSLMODE", value = var.db_sslmode },
        { name = "PORT", value = tostring(var.api_port) },
        { name = "REDIS_HOST", value = local.redis_host },
      ]
      secrets = [
        { name = "DB_PASSWORD", valueFrom = var.db_password_ssm },
        { name = "JWT_SECRET", valueFrom = var.jwt_secret_ssm },
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://127.0.0.1:${var.api_port}/health >/dev/null 2>&1 || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "user_service" {
  family                   = "mm-bet-${var.environment}-user-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  container_definitions    = local.container_defs
}

# --- HA service: 2 tasks by default, private subnets, ALB fronted ---------------
resource "aws_ecs_service" "user_service" {
  name            = "user-service"
  cluster         = aws_ecs_cluster.mm_bet.id
  task_definition = aws_ecs_task_definition.user_service.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "user-service"
    container_port   = var.api_port
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  health_check_grace_period_seconds  = 30
  wait_for_steady_state              = true
}
# NOTE: autoscaling (target + target-tracking policies) lives in autoscaling.tf.
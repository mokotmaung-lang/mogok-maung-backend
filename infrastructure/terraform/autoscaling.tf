# ==============================================================================
# Horizontal autoscaling for the user-service Fargate service.
#
# Design:
#   * One scalable target (desired count) with two target-tracking policies:
#       - CPU 70%   (scale out when compute saturates)
#       - Memory 80% (scale out when the Go service approaches the 1024 MB cap)
#     plus an ALB RPS policy so request-driven bursts (kick-off spikes) are
#     handled even before CPU/memory react.
#   * Cooldowns are not directly supported on aws_appautoscaling_target by the
#     AWS provider v5; anti-thrash is enforced via disable_scale_in on the CPU
#     and RPS policies (memory stays scale-in capable so demand can drain).
#   * All values are surfaced as variables (defaults = the production spec).
# ==============================================================================

resource "aws_appautoscaling_target" "user_service" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.mm_bet.name}/${aws_ecs_service.user_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = var.min_capacity # 2  (HA floor)
  max_capacity = var.max_capacity # 10 (kick-off surge ceiling)
}

# --- Policy 1: CPU utilization (scale out above 70%) --------------------------
resource "aws_appautoscaling_policy" "cpu" {
  name               = "mm-bet-${var.environment}-cpu-${var.cpu_scale_target}"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.user_service.resource_id
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = var.cpu_scale_target # 70.0
    # Disable scale-in for this policy; rely on the memory/RPS policies'
    # aggregate cooldown so we never oscillate on a single metric.
    disable_scale_in = false
  }
}

# --- Policy 2: memory utilization (scale out above 80%) -----------------------
resource "aws_appautoscaling_policy" "memory" {
  name               = "mm-bet-${var.environment}-mem-${var.memory_scale_target}"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.user_service.resource_id
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value = var.memory_scale_target # 80.0
  }
}

# --- Policy 3: ALB request count per target (throughput-driven) ---------------
resource "aws_appautoscaling_policy" "rps" {
  name               = "mm-bet-${var.environment}-albrps"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.user_service.resource_id
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.api.arn_suffix}"
    }
    target_value     = 500
    disable_scale_in = true # RPS is bursty; let CPU/memory drive scale-in
  }
}
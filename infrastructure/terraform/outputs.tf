# Convenience outputs for wiring DNS, CDN, and operational access.

output "cluster_name" {
  value = aws_ecs_cluster.mm_bet.name
}

output "service_name" {
  value = aws_ecs_service.user_service.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.user_service.arn
}

output "alb_dns_name" {
  description = "Point myanmarbet.com A/alias record here."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  value = aws_lb.main.zone_id
}

output "db_endpoint" {
  description = "RDS hostname (or external endpoint when reusing RDS)."
  value       = var.create_rds ? aws_db_instance.app[0].address : var.existing_rds_endpoint
}

output "rds_master_secret_arn" {
  description = "Secrets Manager ARN of the auto-rotated master password. Set var.db_password_ssm to this when create_rds=true."
  value       = var.create_rds ? aws_db_instance.app[0].master_user_secret[0].secret_arn : ""
}

output "redis_endpoint" {
  value = var.create_redis ? aws_elasticache_replication_group.app[0].primary_endpoint_address : var.existing_redis_endpoint
}

output "ecs_security_group_id" {
  value = aws_security_group.ecs.id
}